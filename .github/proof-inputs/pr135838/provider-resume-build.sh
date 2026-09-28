set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = 43d74a393a72e7da12456d66079ee291acc2f114
assert_candidate
run_logged build pnpm build
assert_candidate
python3 "$RUNNER_TEMP/publication-artifact.py" retain
