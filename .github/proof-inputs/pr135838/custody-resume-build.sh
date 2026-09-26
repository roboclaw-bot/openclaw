set -euo pipefail
test "$BASE_SHA" = 24c7bd68b4bb683c0f2eb55c278534d635a50403
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD
pnpm build
git diff --quiet HEAD
