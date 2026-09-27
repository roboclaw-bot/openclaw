set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = 7365e3003e1c6ab9e372fc5b1fe673f82c18389e
assert_candidate
run_logged plugin-test-types pnpm tsgo:extensions:test
run_logged root-test-types pnpm tsgo:test:root

assert_candidate
