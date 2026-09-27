set -euo pipefail
test "$BASE_SHA" = e53ea87c66cb5d1deaefe5046069de4adbcde09a
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
test "$EXPECTED_TREE" = 8d016974aecaddff23a9a86ff502f500980cbb4d
test "$(git diff --name-only "$BASE_SHA" HEAD)" = test/vitest/vitest.gateway-server-paths.mjs
git diff --quiet HEAD

# Replay the complete planner owner and adjacent inventory guards together.
/usr/bin/time -f "ROUTING_REPAIR wall_s=%e exit=%x" \
  pnpm test test/scripts/ci-node-test-plan.test.ts \
    test/scripts/type-suppression-inventory.test.ts \
    test/scripts/lint-suppressions.test.ts --maxWorkers=1 --reporter=verbose
pnpm format:check test/vitest/vitest.gateway-server-paths.mjs
git diff --quiet HEAD
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
printf 'ROUTING_REPAIR_PROOF planner_and_inventories=passed source_clean=true\n'
