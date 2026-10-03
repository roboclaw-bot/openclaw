set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = 19d331d185ac1337204a9a80aff913ee1a358572
assert_candidate
run_logged build pnpm build
assert_candidate
python3 "$RUNNER_TEMP/publication-artifact.py" retain
