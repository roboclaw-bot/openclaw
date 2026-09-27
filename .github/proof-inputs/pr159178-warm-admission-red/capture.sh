#!/usr/bin/env bash
# Hosted-only capture-custody test capture. This recipe never converts a failing test to success.
set -euo pipefail
mode=capture-custody
evidence="$RUNNER_TEMP/pr159178-warm-capture-custody-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
support_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
fixture_file=extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
base=bb394585807555813b24f43eb3ceea018134df10
tree=bafe6f4a8d5da82e89c6c030ce8c6031cf511f87
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = 946d2ea7debe010d8c6566bc0456f622e8569643a81a92cf77f236132b4bdc99 &&
    test "$(sha256sum "$support_file" | cut -d ' ' -f1)" = a1a0793e383f3e71ba245d11dd0e251ca3637f3f1ea30a808e2126353d706f7d &&
    test "$(sha256sum "$fixture_file" | cut -d ' ' -f1)" = c6f92d601b575a336b610e8734fed0c450625ed64f77f44c168169ffa69c3996
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
# No user, provider, publishing, or hydrated credentials are supplied to this job.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
command=(pnpm test "$test_file" --maxWorkers=1 --reporter=verbose -t 'capture (dispatch|claim delivery) custody')
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
    classification:"UNCLASSIFIED capture-custody: inspect all five named scenarios, actual admission/runner boundaries, original error identity, durable claims and both controls; a nonzero exit alone is not RED"}' \
  > "$evidence/$mode.result.json"
cat "$evidence/$mode.result.json"
cat "$evidence/$mode.time.txt"
# Keep the test's actual exit status; bookkeeping errors cannot turn it green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
