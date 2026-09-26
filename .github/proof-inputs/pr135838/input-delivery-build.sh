set -euo pipefail
test "$BASE_SHA" = 8ccaaaae043181a9a7861ef4b4c8ad1dfe614351
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm build
git diff --quiet HEAD
