set -euo pipefail
test "$BASE_SHA" = 7a66ecd22a43e6132cfc7e7209a58c86bbafda3c
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/test-helpers.server-storage.test.ts --maxWorkers=2
