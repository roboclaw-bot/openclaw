#!/usr/bin/env bash
# Hosted-only test capture. This recipe never converts a failing test to success.
set -euo pipefail
mode="${1:?focused or full required}"
case "$mode" in focused|full) ;; *) exit 2 ;; esac
evidence="$RUNNER_TEMP/pr159178-warm-red"
test_file=extensions/crabbox/src/crabbox-worker-warm-image-authority.test.ts
base=bb394585807555813b24f43eb3ceea018134df10
tree=04c66892960db7a41be3aaa495e41feccba9490c
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(sha256sum "$test_file" | cut -d ' ' -f1)" = c85ebafc5ebb241b70072ccafab5c894933282a6a785bb70bcc7778f9930e385
}
assert_source
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/$mode.toolchain.txt"
# No user, provider, publishing, or hydrated credentials are supplied to this job.
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}"
command=(pnpm test "$test_file" --maxWorkers=1 --reporter=verbose)
if [[ "$mode" == focused ]]; then
  command+=(-t 'record allocation honors invocation closure at commit with a live physical signal')
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
    classification:"UNCLASSIFIED: inspect exact assertion failures and controls; a nonzero exit alone is not RED"}' \
  > "$evidence/$mode.result.json"
cat "$evidence/$mode.result.json"
cat "$evidence/$mode.time.txt"
# Keep the test's actual exit status; bookkeeping errors cannot turn it green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
