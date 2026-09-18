set -euo pipefail
test "$SUITE" = credential-authority-red
test "$BASE_SHA" = 1e254336b194c48f97342d8dd9024b8e59c14be2
node scripts/run-vitest.mjs run --config test/vitest/vitest.gateway-core.config.ts src/gateway/worker-environments/credential-attachment-authority.behavior.test.ts
