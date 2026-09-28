set -euo pipefail
source "$RUNNER_TEMP/same-commit-source.sh" source
C_PRODUCT="$candidate"
test "$(git rev-parse HEAD^)" = e0a53eaa04e450cf9c287e2f8ae1f687f3afdf23
assert_candidate
run_logged sdk-exports pnpm plugin-sdk:check-exports
run_logged sdk-surface pnpm plugin-sdk:surface:check
run_logged sdk-api pnpm plugin-sdk:api:diff --base "$BASE_SHA" --head "$C_PRODUCT" --summary "$RUNNER_TEMP/candidate-sdk-api.txt" --json "$RUNNER_TEMP/candidate-sdk-api.json"
test -s "$RUNNER_TEMP/candidate-sdk-api.txt"
jq -e . "$RUNNER_TEMP/candidate-sdk-api.json" >/dev/null
sha256sum "$RUNNER_TEMP/candidate-sdk-api.json" > "$evidence/sdk-report.sha256"

assert_candidate
