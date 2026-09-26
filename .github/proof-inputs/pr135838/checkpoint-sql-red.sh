set -euo pipefail
test "$BASE_SHA" = 408d549433560e27f7d7cf76d417ed47f14aa288
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/worker-environments/session-repository-checkpoints.test.ts
