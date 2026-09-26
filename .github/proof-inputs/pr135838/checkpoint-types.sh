set -euo pipefail
test "$BASE_SHA" = 1408b924c23843d8b8f21aae50d705e1aef925a2
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm tsgo:core
changed=$(git diff --name-only "$BASE_SHA" HEAD | jq -Rsc 'split("\n")|map(select(length>0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed" --concurrency 2
git diff --quiet HEAD
