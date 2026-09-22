set -euo pipefail
test "$BASE_SHA" = eeb450c9cf2dd0a29243089a7042a3f0c5882717
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
TIMEFORMAT='elapsed_seconds=%3R'
time pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts --maxWorkers=1
