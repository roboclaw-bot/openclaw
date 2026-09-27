#!/usr/bin/env bash
# Hosted-only sibling-fixture22 test capture. This recipe never converts a failing test to success.
set -euo pipefail
mode="${1:?focused or full required}"
case "$mode" in focused|full) ;; *) exit 2 ;; esac
evidence="$RUNNER_TEMP/pr159178-warm-sibling-fixture22-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test.ts
support_file=extensions/crabbox/src/crabbox-worker-warm-image-sibling-admission.test-support.ts
fixture_file=extensions/crabbox/src/crabbox-worker-warm-image-store.test.ts
base=bb394585807555813b24f43eb3ceea018134df10
tree=772e21f56df84f1eb8e9528c848300a8b2cbc030
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = edafc537f967058f7a1fcbe889dfde0c412fd9d7da8580935466c299ffa644d1 &&
    test "$(sha256sum "$support_file" | cut -d ' ' -f1)" = bef9a018fce8be6f958d1bae221f197bf9b84d6c0f771ac5a42a34d335a95ff1 &&
    test "$(sha256sum "$fixture_file" | cut -d ' ' -f1)" = c6f92d601b575a336b610e8734fed0c450625ed64f77f44c168169ffa69c3996
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
# No user, provider, publishing, or hydrated credentials are supplied to this job.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
command=(pnpm test "$test_file")
if [[ "$mode" == full ]]; then
  command+=("$fixture_file")
fi
command+=(--maxWorkers=1 --reporter=verbose)
if [[ "$mode" == focused ]]; then
  command+=(-t 'refuses post-fork metadata and independently stops the dispatched lease before releasing its hold')
fi
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
    classification:"UNCLASSIFIED sibling-fixture22: inspect exact assertion failures and controls; a nonzero exit alone is not RED"}' \
  > "$evidence/$mode.result.json"
cat "$evidence/$mode.result.json"
cat "$evidence/$mode.time.txt"
# Keep the test's actual exit status; bookkeeping errors cannot turn it green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
