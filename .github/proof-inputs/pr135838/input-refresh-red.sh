set -euo pipefail
test "$BASE_SHA" = 8be6c5adf3f7b76a52278800e4f75ec9f36c1720
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/server.agent-runtime-authority-proof.test.ts
