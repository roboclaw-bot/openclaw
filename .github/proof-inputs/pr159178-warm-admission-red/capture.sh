#!/usr/bin/env bash
# Hosted-only expiry-teardown diagnostic; native failure remains job failure.
set -euo pipefail
mode=expiry-teardown
phase="${1:-runtime}"
case "$phase" in
  runtime) ;;
  types) mode=expiry-teardown-types ;;
  format) mode=expiry-teardown-format ;;
  *) exit 2 ;;
esac
evidence="$RUNNER_TEMP/pr159178-expiry-teardown-red"
test_file=extensions/crabbox/src/crabbox-worker-prepared-image.test.ts
control_file=extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
base=fd0b54a58f93b68a49eb07695705cd770ebb91b1
product=b99494f43807dccc858baef1fc169d2f2c2d33e5
product_tree=4e02b1417735ecfa62c645c427d44108cdf98d62
tree=b36cbe34ac7f273a7c03205bedabbf7f561a40d7
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    git diff --quiet "$product_tree" "$tree" -- . ":(exclude)$test_file" &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = 1f63de2979e855f8205204d2a4a901e3013f8258b56f848e500dc67b3fea9353 &&
    sha256sum --check "$evidence/source-files.sha256" &&
    git ls-files --stage &&
    git rev-parse HEAD && git write-tree
}
# After canonical setup and before EVERY phase: bind the tracked index/worktree.
assert_source > "$evidence/$mode.pre-source-check.log" 2>&1
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
test "$(node --version)" = v24.19.0
test "$(pnpm --version)" = 12.5.0
# Candidate commands receive no GitHub/package transport credentials.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
if [[ "$phase" != runtime ]]; then
  jq -e '.teeExitStatus == 0 and .sourceCheckExitStatus == 0 and
    (.nativeExitStatus == 0 or .nativeExitStatus == 1)' "$evidence/expiry-teardown.result.json" >/dev/null
fi
case "$phase" in
  runtime) command=(pnpm test "$test_file" "$control_file" --maxWorkers=1 --reporter=verbose --reporter=./scripts/lib/vitest-resource-reporter.mts --logHeapUsage) ;;
  types) command=(pnpm tsgo:extensions:test) ;;
  format) command=(pnpm format:check "$test_file") ;;
esac
printf '%q ' "${command[@]}" > "$evidence/$mode.command.txt"
printf '\n' >> "$evidence/$mode.command.txt"
started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf '%s\n' "$started" > "$evidence/$mode.started.txt"
set +e
timeout --signal=TERM --kill-after=30s 10m /usr/bin/time -f 'wall_seconds=%e user_seconds=%U system_seconds=%S maxrss_kib=%M native_exit=%x' -o "$evidence/$mode.time.txt" "${command[@]}" 2>&1 | tee "$evidence/$mode.log"
statuses=("${PIPESTATUS[@]}")
ended="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
source_status=0
assert_source > "$evidence/$mode.source-check.log" 2>&1 || source_status=$?
# Bookkeeping cannot mask native failure or authorize follow-ups after an unsettled run.
(
  set -e
  jq -n --arg mode "$mode" --arg phase "$phase" --arg started "$started" --arg ended "$ended" \
    --arg base "$base" --arg product "$product" --arg productTree "$product_tree" --arg tree "$tree" \
    --argjson nativeStatus "${statuses[0]}" --argjson logStatus "${statuses[1]}" \
    --argjson sourceStatus "$source_status" \
    '{mode:$mode,phase:$phase,startedAt:$started,endedAt:$ended,runtimeHead:$base,productCommit:$product,productTree:$productTree,tree:$tree,
      nativeExitStatus:$nativeStatus,teeExitStatus:$logStatus,sourceCheckExitStatus:$sourceStatus,
      sourceIdentity:"fd0 HEAD with genuine b994 product bytes and diagnostic prepared-image test overlay",
      classification:"UNCLASSIFIED: native result requires assertion-level adjudication; no expected exit or passing-count claim",
      caseLabelPolicy:"Native verbose log retained unchanged; labels may be ellipsized. Expected observations are separate metadata, not native output."}' \
    > "$evidence/$mode.result.json"
  cat "$evidence/$mode.result.json"
  if [[ -f "$evidence/$mode.time.txt" ]]; then cat "$evidence/$mode.time.txt"; fi
  if [[ "$phase" == runtime ]] && (( statuses[0] <= 1 && statuses[1] == 0 && source_status == 0 )); then
    printf 'settled=true\n' >> "$GITHUB_OUTPUT"
  fi
)
record_status=$?
set -e
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
if (( source_status != 0 )); then exit "$source_status"; fi
exit "$record_status"
