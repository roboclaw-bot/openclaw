set -euo pipefail
test "$BASE_SHA" = 8681a848844a05afd0f944c1ad1900332d5d80bc
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
pnpm test src/gateway/worker-environments/desktop-ssh-identity.test.ts src/gateway/worker-environments/bootstrap.test.ts src/gateway/worker-environments/identity.test.ts src/gateway/worker-environments/provider-ssh-identity.test.ts src/gateway/worker-environments/ssh.test.ts src/gateway/worker-environments/tunnel.test.ts src/gateway/worker-environments/provider-bootstrap.test.ts src/gateway/worker-environments/desktop-tunnel.test.ts src/gateway/worker-environments/environment-access.test.ts src/gateway/worker-environments/provider-runtime-refresh.test.ts src/gateway/worker-environments/provider-owner-revocation.test.ts src/gateway/worker-environments/service-lifetime.test.ts src/gateway/worker-environments/store-worker.test.ts src/gateway/worker-environments/store-projection.test.ts test/vitest-projects-config.test.ts src/gateway/server-import-boundary.test.ts

# Record the current repository-required per-changed-test wall cost.
TIMEFORMAT='elapsed_seconds=%3R'
for file in "${typescript[@]}"; do
  if [[ "$file" == *.test.ts ]]; then
    printf '\nTest-cost benchmark: %s\n' "$file"
    time pnpm test "$file" --maxWorkers=1
  fi
done
git diff --quiet HEAD
# Type and source SDK checks run separately; ordinary exact-head PR CI owns
# its canonical runtime/build gates. No full-build success is implied by this lane.
