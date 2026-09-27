set -euo pipefail
test "$BASE_SHA" = 19c6ef8d9e0260471b798615e8a1eaf42b9aada3
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
# Reviewed cleanup must pass the actual 33-case snapshot file on this composition.
/usr/bin/time -f 'SNAPSHOT_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test src/skills/runtime/session-snapshot.integration.test.ts --maxWorkers=1
# Preserve upstream #159127; registered wrapper asserts all 19 native cases.
/usr/bin/time -f 'UPDATER_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test test/scripts/update-restart-module-outcome.test.ts

test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD
