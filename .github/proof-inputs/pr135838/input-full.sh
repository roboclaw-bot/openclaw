set -euo pipefail
test "$SUITE" = input-full
pnpm test src/gateway/agent-turn/agent-run-user-turn.test.ts src/gateway/server-methods/agent.test.ts src/gateway/server-methods/agent-run-local-operator-authority.test.ts src/gateway/agent-turn/internal-facade.test.ts
pnpm check:line-cap-ratchet --base 3e8b396a7dc833185c0fdba33efadef6826eeda7
pnpm check:max-lines-ratchet --base 3e8b396a7dc833185c0fdba33efadef6826eeda7
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json src/gateway/server-methods/agent.reset-and-identity.test-utils.ts src/gateway/server-methods/agent.reset-authority.test-support.ts
node scripts/run-tsgo-core-test-shards.mjs --changed-paths-json '["src/gateway/server-methods/agent.reset-and-identity.test-utils.ts","src/gateway/server-methods/agent.reset-authority.test-support.ts"]'
./node_modules/.bin/oxfmt --check src/gateway/server-methods/agent.reset-and-identity.test-utils.ts src/gateway/server-methods/agent.reset-authority.test-support.ts
git diff --check "$BASE_SHA" HEAD
git diff --quiet HEAD
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
