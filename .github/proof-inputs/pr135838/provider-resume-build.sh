set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = fd0b54a58f93b68a49eb07695705cd770ebb91b1
assert_candidate
run_logged build pnpm build
assert_candidate
