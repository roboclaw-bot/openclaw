set -euo pipefail
test "$BASE_SHA" = 408d549433560e27f7d7cf76d417ed47f14aa288
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
# Run 36217827773 passed core and six graphs before fail-fast stopped the queue.
# Resume the failed gateway-other graph and all eighteen unrun canonical graphs.
pnpm lint:tmp:tsgo-core-boundary
node scripts/run-tsgo-core-test-shards.mjs --ci-graphs-json '["core-test-gateway-other","core-test-state-logging","core-test-commands","core-test-plugins-platform","core-test-config-cli","core-test-messaging","core-test-services","core-test-other","core-test-ui-pages","core-test-ui-e2e","core-test-ui-other","core-test-packages","core-test-plugin-sdk","core-test-commands-doctor","core-test-cli-update","core-test-gateway-methods","core-test-ui-chat","core-test-agents-sessions","core-test-services-cron"]' --concurrency 2
git diff --quiet HEAD
