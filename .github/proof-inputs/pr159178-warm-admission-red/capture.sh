#!/usr/bin/env bash
# Hosted-only retirement-custody test capture. This recipe never converts a failing test to success.
set -euo pipefail
mode=retirement-custody
evidence="$RUNNER_TEMP/pr159178-warm-retirement-custody-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
support_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
fixture_file=extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
base=bb394585807555813b24f43eb3ceea018134df10
tree=3d8fb85a1c1277767a2b9e93fdf4565226eaa085
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = 642aa11e3ad313667d798a110328f6b8b5fcd3d928111049fa62d8e8d5da6153 &&
    test "$(sha256sum "$support_file" | cut -d ' ' -f1)" = bef9a018fce8be6f958d1bae221f197bf9b84d6c0f771ac5a42a34d335a95ff1 &&
    test "$(sha256sum "$fixture_file" | cut -d ' ' -f1)" = c6f92d601b575a336b610e8734fed0c450625ed64f77f44c168169ffa69c3996
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
# No user, provider, publishing, or hydrated credentials are supplied to this job.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
command=(pnpm test "$test_file" --maxWorkers=1 --reporter=verbose -t 'settles confirmed single-catalog deletion')
printf '%q ' "${command[@]}" > "$evidence/$mode.command.txt"
printf '\n' >> "$evidence/$mode.command.txt"
started="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
printf '%s\n' "$started" > "$evidence/$mode.started.txt"
# Catch only this native pipeline to record both statuses, then propagate failure.
set +e
/usr/bin/time -f 'wall_seconds=%e user_seconds=%U system_seconds=%S native_exit=%x' -o "$evidence/$mode.time.txt" "${command[@]}" 2>&1 | tee "$evidence/$mode.log"
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
    classification:"UNCLASSIFIED retirement-custody: inspect both named failure boundaries and retained durable debt; a nonzero exit alone is not RED"}' \
  > "$evidence/$mode.result.json"
cat "$evidence/$mode.result.json"
cat "$evidence/$mode.time.txt"
# Keep the test's actual exit status; bookkeeping errors cannot turn it green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
