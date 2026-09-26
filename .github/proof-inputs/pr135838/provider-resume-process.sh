set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
node scripts/run-vitest.mjs run --config test/vitest/vitest.gateway-database-workers.config.ts src/gateway/worker-environments/provider-host-authority.process.test.ts --reporter=verbose

git diff --quiet HEAD
