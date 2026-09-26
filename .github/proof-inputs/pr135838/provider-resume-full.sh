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
/usr/bin/time -f 'DELEGATION_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts extensions/crabbox/src/crabbox-worker-provision-commands.test.ts src/gateway/worker-environments/provider-invocation.test.ts --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts
pnpm test extensions/crabbox/src/crabbox-worker-provider.test.ts extensions/crabbox/src/crabbox-worker-project.test.ts extensions/crabbox/src/crabbox-worker-prepared-image.test.ts extensions/crabbox/src/crabbox-worker-warm-image-allocation.test.ts extensions/crabbox/src/crabbox-worker-warm-image-lifecycle.test.ts extensions/crabbox/src/crabbox-worker-warm-image-maintenance.test.ts extensions/crabbox/src/crabbox-worker-warm-image-retirement.test.ts src/gateway/worker-environments/provider-provisioning.test.ts src/gateway/worker-environments/provider-provisioning-node.test.ts src/gateway/worker-environments/provider-provisioning.replay.test.ts src/gateway/worker-environments/provider-provisioning.cancellation.test.ts src/gateway/worker-environments/provider-project-preparation.test.ts src/gateway/worker-environments/provider-crabbox-runtime-preflight.test.ts src/gateway/worker-environments/identity.test.ts src/gateway/worker-environments/device-provider.test.ts extensions/qa-lab/src/static-ssh-worker-provider.test.ts extensions/crabbox/index.test.ts test/plugins/crabbox-service-replacement.test.ts test/helpers/desktop-resize-real-fixture.test.ts src/plugins/worker-provider-registry.test.ts src/plugin-sdk/worker-provider.contract.test.ts

git diff --quiet HEAD
