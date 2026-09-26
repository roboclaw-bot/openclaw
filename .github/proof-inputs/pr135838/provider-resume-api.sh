set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm plugin-sdk:check-exports
pnpm plugin-sdk:surface:check
pnpm plugin-sdk:api:diff --base "$BASE_SHA" --head HEAD --summary "$RUNNER_TEMP/candidate-sdk-api.txt" --json "$RUNNER_TEMP/candidate-sdk-api.json"
test -s "$RUNNER_TEMP/candidate-sdk-api.txt"
jq -e . "$RUNNER_TEMP/candidate-sdk-api.json" >/dev/null

git diff --quiet HEAD
