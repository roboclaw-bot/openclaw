set -euo pipefail
test "$BASE_SHA" = f7dc8adeeec2ee608d1d58846bbd4c7d30533bdb
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
base="$BASE_SHA"
pnpm tsgo:core
changed=$(git diff --name-only "$base" HEAD | jq -Rsc 'split("\n")|map(select(length>0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed" --concurrency 2
git diff --quiet HEAD
