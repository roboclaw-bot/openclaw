set -euo pipefail
test "$BASE_SHA" = 1408b924c23843d8b8f21aae50d705e1aef925a2
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
pnpm test src/gateway/worker-environments/session-repository-checkpoints.test.ts src/gateway/worker-environments/workspace-result-repository.test.ts
