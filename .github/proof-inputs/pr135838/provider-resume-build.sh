set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23
assert_candidate
run_logged build pnpm build
assert_candidate
python3 "$RUNNER_TEMP/publication-artifact.py" retain
