set -euo pipefail
test "$BASE_SHA" = 7a66ecd22a43e6132cfc7e7209a58c86bbafda3c
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
base="$BASE_SHA"
pnpm tsgo:core
changed=$(git diff --name-only "$base" HEAD | jq -Rsc 'split("\n")|map(select(length>0))')
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json "$changed" --concurrency 2
git diff --quiet HEAD
