set -euo pipefail
test "$BASE_SHA" = 8681a848844a05afd0f944c1ad1900332d5d80bc
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm plugin-sdk:check-exports
pnpm plugin-sdk:surface:check
pnpm plugin-sdk:api:diff --base "$BASE_SHA" --head HEAD --summary "$RUNNER_TEMP/candidate-sdk-api.txt" --json "$RUNNER_TEMP/candidate-sdk-api.json"
test -s "$RUNNER_TEMP/candidate-sdk-api.txt"
jq -e . "$RUNNER_TEMP/candidate-sdk-api.json" >/dev/null
git diff --quiet HEAD
# Source API report, not compiled distribution proof or approval. Ordinary
# exact-head PR CI retains its canonical build gates. Parent inspects this report.
