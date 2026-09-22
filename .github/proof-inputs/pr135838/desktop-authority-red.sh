set -euo pipefail
test "$BASE_SHA" = 7ad083994368c4f0115884e7885774101f7997ca
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
TIMEFORMAT='elapsed_seconds=%3R'
time pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts --maxWorkers=1
