set -euo pipefail
test "$BASE_SHA" = 8681a848844a05afd0f944c1ad1900332d5d80bc
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
base="$BASE_SHA"
pnpm tsgo:core
changed=$(git diff --name-only "$base" HEAD | jq -Rsc 'split("\n")|map(select(length>0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed" --concurrency 2
git diff --quiet HEAD
