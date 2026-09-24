set -euo pipefail
test "$BASE_SHA" = f9da9a55a1ddb12b874b62ee1129b6bbb9edbd3d
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/test-helpers.server-storage.test.ts --maxWorkers=2
