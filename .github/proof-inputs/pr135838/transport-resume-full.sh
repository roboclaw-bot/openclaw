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
/usr/bin/time -f 'DELEGATION_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test src/gateway/worker-environments/environment-access-authority.test.ts src/gateway/worker-environments/node-worker-repository-authority.test.ts src/gateway/worker-environments/node-worker-tunnel-authority.test.ts src/gateway/worker-environments/node-worker-workspace-actions.test.ts src/gateway/worker-environments/placement-dispatch-transport-authority.test.ts --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts
pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts src/gateway/worker-environments/environment-access.test.ts src/gateway/worker-environments/node-worker-tunnel.lifecycle.test.ts src/gateway/worker-environments/node-worker-tunnel.session-processes.test.ts src/gateway/worker-environments/node-worker-tunnel.test.ts src/gateway/worker-environments/node-worker-workspace-fallback.test.ts src/gateway/worker-environments/node-workspace-transfer-command.test.ts src/gateway/worker-environments/node-workspace-transfer-credential.test.ts src/gateway/worker-environments/node-workspace-transfer-encoding.test.ts src/gateway/worker-environments/node-workspace-transfer-pack.test.ts src/gateway/worker-environments/node-workspace-transfer-retention.test.ts src/gateway/worker-environments/node-workspace-transfer-revocation.test.ts src/gateway/worker-environments/node-workspace-transfer-service.test.ts src/gateway/worker-environments/placement-dispatch-authority.test.ts src/gateway/worker-environments/placement-dispatch-device.test.ts src/gateway/worker-environments/placement-dispatch-prepared.test.ts src/gateway/worker-environments/placement-dispatch-recovery.test.ts src/gateway/worker-environments/placement-dispatch-shutdown.test.ts src/gateway/worker-environments/repository-workspace-startup.test.ts src/gateway/worker-environments/ssh.test.ts src/gateway/worker-environments/tunnel.test.ts src/gateway/worker-environments/workspace-sync-tunnel.test.ts

git diff --quiet HEAD
