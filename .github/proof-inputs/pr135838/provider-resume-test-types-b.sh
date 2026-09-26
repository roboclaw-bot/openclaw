set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
changed_json=$(git diff --name-only "$BASE_SHA" HEAD -- '*.ts' | jq -Rsc 'split("\n") | map(select(length > 0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed_json" --stripe 2/2

git diff --quiet HEAD
