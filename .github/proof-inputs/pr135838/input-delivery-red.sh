set -euo pipefail
test "$BASE_SHA" = 8ccaaaae043181a9a7861ef4b4c8ad1dfe614351
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
/usr/bin/time -f 'PR150640_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' env OPENCLAW_VITEST_MAX_WORKERS=1 pnpm test src/gateway/server.agent-runtime-authority-proof.test.ts --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts
