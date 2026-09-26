set -euo pipefail
test "$BASE_SHA" = 24c7bd68b4bb683c0f2eb55c278534d635a50403
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm tsgo:core
changed_json=$(git diff --name-only "$BASE_SHA" HEAD -- '*.ts' | jq -Rsc 'split("\n") | map(select(length > 0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed_json"

git diff --quiet HEAD
