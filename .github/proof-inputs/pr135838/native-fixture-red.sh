set -euo pipefail
test "$BASE_SHA" = f7dc8adeeec2ee608d1d58846bbd4c7d30533bdb
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/test-helpers.server-storage.test.ts --maxWorkers=2
