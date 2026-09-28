set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = 43d74a393a72e7da12456d66079ee291acc2f114
assert_candidate
changed_json=$(git diff --name-only "$BASE_SHA" "$C_PRODUCT" -- '*.ts' | jq -Rsc 'split("\n") | map(select(length > 0))')
printf '%s\n' "$changed_json" > "$evidence/changed-paths.json"
run_logged core-test-types node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed_json" --stripe 1/2

assert_candidate
