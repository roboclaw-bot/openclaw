#!/usr/bin/env bash
# Hosted-only publication-fence capture; never converts native failure to success.
set -euo pipefail
mode=publication-fence
phase="${1:-runtime}"
case "$phase" in runtime) ;; types) mode=publication-fence-types ;; *) exit 2 ;; esac
evidence="$RUNNER_TEMP/pr159178-publication-fence-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
sibling_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
base=fd0b54a58f93b68a49eb07695705cd770ebb91b1
product=a95aa9917bedf89d80d41f089b508a3a1658c4ae
tree=05dcb558dba760d1ad1a408fcc244a545faa8d65
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = 70ef3d0941c581a3002944433ee13150f257bcd82971b4feb0f62c670edf6bd8
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
test "$(node --version)" = v24.19.0
test "$(pnpm --version)" = 12.5.0
# GitHub action transport credentials are never supplied to candidate commands.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
if [[ "$phase" == types ]]; then
  # Exactly one canonical compiler, only after settled native runtime and intact source/log.
  jq -e '.teeExitStatus == 0 and .sourceCheckExitStatus == 0 and
    (.nativeExitStatus == 0 or .nativeExitStatus == 1)' "$evidence/publication-fence.result.json" >/dev/null
  command=(pnpm tsgo:extensions:test)
else
  command=(pnpm test "$test_file" "$sibling_file" --maxWorkers=1 --reporter=verbose)
fi
printf '%q ' "${command[@]}" > "$evidence/$mode.command.txt"
printf '\n' >> "$evidence/$mode.command.txt"
started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf '%s\n' "$started" > "$evidence/$mode.started.txt"
# Keep both pipeline statuses; timeouts and errors remain native failures.
set +e
timeout --signal=TERM --kill-after=30s 10m /usr/bin/time -f 'wall_seconds=%e user_seconds=%U system_seconds=%S native_exit=%x' -o "$evidence/$mode.time.txt" "${command[@]}" 2>&1 | tee "$evidence/$mode.log"
statuses=("${PIPESTATUS[@]}")
ended="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
source_status=0
assert_source > "$evidence/$mode.source-check.log" 2>&1 || source_status=$?
# Bookkeeping failure must neither mask a native timeout nor authorize the type step.
(
  set -e
  jq -n --arg mode "$mode" --arg phase "$phase" --arg started "$started" --arg ended "$ended" \
    --arg base "$base" --arg product "$product" --arg tree "$tree" \
    --argjson nativeStatus "${statuses[0]}" --argjson logStatus "${statuses[1]}" \
    --argjson sourceStatus "$source_status" \
    '{mode:$mode,startedAt:$started,endedAt:$ended,runtimeHead:$base,productionSha:$product,tree:$tree,
      nativeExitStatus:$nativeStatus,teeExitStatus:$logStatus,sourceCheckExitStatus:$sourceStatus,
      sourceIdentity:"fd0 HEAD with A95 production bytes plus one reviewed test overlay; not actual A95 commit execution",
      classification:(if $phase == "runtime" then "UNCLASSIFIED: require all 44 cases, three intended semantic failures and 41 passing controls; prediction, not observation" else "UNCLASSIFIED canonical plugin test types; inspect diagnostics separately, not runtime RED" end)}' \
    > "$evidence/$mode.result.json"
  cat "$evidence/$mode.result.json"
  if [[ -f "$evidence/$mode.time.txt" ]]; then cat "$evidence/$mode.time.txt"; fi
  if [[ "$phase" == runtime ]] && (( statuses[0] <= 1 && statuses[1] == 0 && source_status == 0 )); then
    printf 'settled=true\n' >> "$GITHUB_OUTPUT"
  fi
)
record_status=$?
set -e
# Preserve native, tee, source, then bookkeeping status in that order.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
if (( source_status != 0 )); then exit "$source_status"; fi
exit "$record_status"
