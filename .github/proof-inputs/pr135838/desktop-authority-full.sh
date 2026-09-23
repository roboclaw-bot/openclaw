set -euo pipefail
test "$BASE_SHA" = f7dc8adeeec2ee608d1d58846bbd4c7d30533bdb
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
base="$BASE_SHA"
mapfile -t changed_files < <(git diff --name-only "$base" HEAD)
mapfile -t typescript < <(git diff --name-only "$base" HEAD -- '*.ts')
git diff --check "$base" HEAD
./node_modules/.bin/oxfmt --check "${changed_files[@]}"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json "${typescript[@]}"
pnpm check:line-cap-ratchet --base "$base"
pnpm check:max-lines-ratchet --base "$base"
pnpm check:assertion-safety --base "$base"
pnpm check:env-var-count --base "$base"
pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts src/gateway/worker-environments/bootstrap.test.ts src/gateway/worker-environments/identity.test.ts src/gateway/worker-environments/provider-ssh-identity.test.ts src/gateway/worker-environments/ssh.test.ts src/gateway/worker-environments/tunnel.test.ts src/gateway/worker-environments/provider-bootstrap.test.ts src/gateway/worker-environments/desktop-tunnel.test.ts src/gateway/worker-environments/environment-access.test.ts src/gateway/worker-environments/provider-runtime-refresh.test.ts src/gateway/worker-environments/store-worker.test.ts src/gateway/worker-environments/store-projection.test.ts test/vitest-projects-config.test.ts src/gateway/test-helpers.server-storage.test.ts src/gateway/test-helpers.server-env.test.ts src/gateway/test-helpers.server-rpc.test.ts src/gateway/test-helpers.acquisition.test.ts

# Record the current repository-required per-changed-test wall cost.
TIMEFORMAT='elapsed_seconds=%3R'
for file in "${typescript[@]}"; do
  if [[ "$file" == *.test.ts ]]; then
    printf '\nTest-cost benchmark: %s\n' "$file"
    time pnpm test "$file" --maxWorkers=1
  fi
done
git diff --quiet HEAD
# Type checks and build/SDK compatibility run separately on this exact base/tree.
# All fixed lanes are required; splitting preserves the 40-minute per-job budget.
