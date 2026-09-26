set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
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
/usr/bin/time -f 'DELEGATION_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test src/gateway/worker-environments/credential-attachment-authority.test.ts --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts
pnpm test src/gateway/worker-environments/credential-broker.test.ts src/gateway/worker-environments/placement-dispatch-device.test.ts src/gateway/worker-environments/placement-dispatch-prepared.test.ts src/gateway/worker-environments/prepared-environment-store.test.ts src/gateway/worker-environments/store-worker.test.ts src/gateway/worker-environments/store-recovery.worker.test.ts src/gateway/worker-environments/service-lifetime.test.ts src/gateway/worker-environments/service.plugin-create.test.ts
git diff --quiet HEAD
