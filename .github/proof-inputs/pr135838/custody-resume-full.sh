set -euo pipefail
test "$BASE_SHA" = 24c7bd68b4bb683c0f2eb55c278534d635a50403
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD
mapfile -t changed_files < <(git diff --name-only "$BASE_SHA" HEAD)
mapfile -t lint_files < <(git diff --name-only "$BASE_SHA" HEAD -- '*.ts' '*.mts' '*.js' '*.mjs')
git diff --check "$BASE_SHA" HEAD
node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD --dry-run
./node_modules/.bin/oxfmt --check "${changed_files[@]}"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.json "${lint_files[@]}"
pnpm check:line-cap-ratchet --base "$BASE_SHA"
pnpm check:max-lines-ratchet --base "$BASE_SHA"
pnpm check:assertion-safety --base "$BASE_SHA"
pnpm check:env-var-count --base "$BASE_SHA"
# Focused lane already runs both changed Linux files separately; do not double-count them here.
pnpm test src/gateway/worker-environments/workspace-result-finalize.test.ts src/gateway/worker-environments/repository-workspace-startup.test.ts src/gateway/worker-environments/placement-dispatch-reclaim.test.ts src/gateway/worker-environments/placement-dispatch-staged-results.test.ts src/gateway/worker-environments/placement-dispatch-continuity.test.ts src/gateway/worker-workspace-recovery-binding.test.ts
git diff --quiet HEAD
