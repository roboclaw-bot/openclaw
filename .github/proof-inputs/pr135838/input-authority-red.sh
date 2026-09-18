set -euo pipefail
test "$SUITE" = input-authority-red
test "$BASE_SHA" = 3e8b396a7dc833185c0fdba33efadef6826eeda7
pnpm test src/gateway/server.agent-runtime-authority-proof.test.ts
