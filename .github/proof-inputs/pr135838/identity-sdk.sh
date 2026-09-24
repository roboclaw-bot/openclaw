set -euo pipefail
test "$BASE_SHA" = 4f6eb26b1beda60044ee9b94cd352f37c63718e9
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm build
pnpm plugin-sdk:check-exports
pnpm plugin-sdk:surface:check
pnpm plugin-sdk:api:diff --base "$BASE_SHA" --head HEAD --summary "$RUNNER_TEMP/candidate-sdk-api.txt" --json "$RUNNER_TEMP/candidate-sdk-api.json"
pnpm build:plugin-sdk:strict-smoke
test -s "$RUNNER_TEMP/candidate-sdk-api.txt"
jq -e . "$RUNNER_TEMP/candidate-sdk-api.json" >/dev/null
git diff --quiet HEAD
# Report generation is NOT compatibility approval. The workflow exports
# compatibilityReview.status=required and the exact report SHA-256.
# Publication requires inspection and acceptance of that bound report; never
# acknowledge its digest automatically. Combine runtime/build receipts only
# when base, source tree and dependency inputs are exactly identical.
