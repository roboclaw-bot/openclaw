set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
/usr/bin/time -f 'DELEGATION_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts extensions/crabbox/src/crabbox-worker-provision-commands.test.ts src/gateway/worker-environments/provider-invocation.test.ts --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts

git diff --quiet HEAD
