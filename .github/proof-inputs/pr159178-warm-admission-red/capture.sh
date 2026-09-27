#!/usr/bin/env bash
# Hosted-only capture-recovery test capture. This recipe never converts a failing test to success.
set -euo pipefail
mode=capture-recovery
phase="${1:-runtime}"
case "$phase" in runtime) ;; types) mode=capture-recovery-types ;; *) exit 2 ;; esac
evidence="$RUNNER_TEMP/pr159178-warm-capture-recovery-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
support_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
fixture_file=extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
base=0edae198d278686e16426f7ad254d0341bd6e3d3
tree=9700a99108547ead6e56c131cbde10cb2cc54914
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = aae513314c2fbc711a07748bd08dbcef255edc350a5639b5180caba14de182b4 &&
    test "$(sha256sum "$support_file" | cut -d ' ' -f1)" = a73d5f9b531762a5a9c1ca3f016b37f922d515957af7118a206c8a25be9e3db8 &&
    test "$(sha256sum "$fixture_file" | cut -d ' ' -f1)" = c6f92d601b575a336b610e8734fed0c450625ed64f77f44c168169ffa69c3996
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
# No user, provider, publishing, or hydrated credentials are supplied to this job.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
if [[ "$phase" == types ]]; then
  # Type reproduction must not overlap a timed-out or incomplete native test.
  jq -e '.teeExitStatus == 0 and .sourceCheckExitStatus == 0 and
    (.nativeExitStatus == 0 or .nativeExitStatus == 1)' "$evidence/capture-recovery.result.json" >/dev/null
  command=(pnpm tsgo:extensions)
else
  command=(pnpm test "$test_file" --maxWorkers=1 --reporter=verbose -t 'capture (recovery precedence|(dispatch|claim delivery) custody)')
fi
printf '%q ' "${command[@]}" > "$evidence/$mode.command.txt"
printf '\n' >> "$evidence/$mode.command.txt"
started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf '%s\n' "$started" > "$evidence/$mode.started.txt"
# Catch only this native pipeline to record both statuses, then propagate failure.
set +e
timeout --signal=TERM --kill-after=30s 10m /usr/bin/time -f 'wall_seconds=%e user_seconds=%U system_seconds=%S native_exit=%x' -o "$evidence/$mode.time.txt" "${command[@]}" 2>&1 | tee "$evidence/$mode.log"
statuses=("${PIPESTATUS[@]}")
set -e
ended="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
source_status=0
assert_source > "$evidence/$mode.source-check.log" 2>&1 || source_status=$?
jq -n --arg mode "$mode" --arg started "$started" --arg ended "$ended" \
  --arg base "$base" --arg tree "$tree" \
  --argjson nativeStatus "${statuses[0]}" --argjson logStatus "${statuses[1]}" \
  --argjson sourceStatus "$source_status" \
  '{mode:$mode,startedAt:$started,endedAt:$ended,baseSha:$base,tree:$tree,
    nativeExitStatus:$nativeStatus,teeExitStatus:$logStatus,sourceCheckExitStatus:$sourceStatus,
    classification:"UNCLASSIFIED: runtime requires all eleven named cases, intended exact-selector failures and passing controls; types requires the native diagnostic at unchanged capture owner. A nonzero exit alone is not RED"}' \
  > "$evidence/$mode.result.json"
cat "$evidence/$mode.result.json"
cat "$evidence/$mode.time.txt"
# Keep the test's actual exit status; bookkeeping errors cannot turn it green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
