set -euo pipefail
test "$BASE_SHA" = 4f6eb26b1beda60044ee9b94cd352f37c63718e9
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/session-row-placement-projection.lifecycle.test.ts --maxWorkers=2
git diff --quiet HEAD
