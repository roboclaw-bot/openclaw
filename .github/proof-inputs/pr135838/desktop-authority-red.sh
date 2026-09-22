set -euo pipefail
test "$BASE_SHA" = aeea6d749c6a82d456c707623dae34ad41c8c096
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
TIMEFORMAT='elapsed_seconds=%3R'
time pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts --maxWorkers=1
