set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23
assert_candidate
run_logged full-lint pnpm lint
assert_candidate
run_logged plugin-test-types pnpm tsgo:extensions:test
run_logged root-test-types pnpm tsgo:test:root

assert_candidate
