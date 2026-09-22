set -euo pipefail
test "$BASE_SHA" = aeea6d749c6a82d456c707623dae34ad41c8c096
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
