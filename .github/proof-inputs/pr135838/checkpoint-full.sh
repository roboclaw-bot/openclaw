set -euo pipefail
test "$BASE_SHA" = 1408b924c23843d8b8f21aae50d705e1aef925a2
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
pnpm test src/gateway/worker-environments/session-repository-checkpoints.test.ts src/gateway/worker-environments/workspace-result-repository.test.ts src/gateway/worker-environments/workspace-result-ref-mutation.test.ts src/gateway/worker-environments/workspace-result-staging.concurrent.test.ts src/gateway/worker-environments/workspace-result-staging.reads.test.ts src/gateway/worker-environments/workspace-reconcile-publication.test.ts src/gateway/worker-environments/workspace-reconcile.test.ts src/gateway/worker-environments/repository-workspace-startup.test.ts src/process/exec-input-admission.test.ts
TIMEFORMAT='elapsed_seconds=%3R'
for file in "${typescript[@]}"; do
  if [[ "$file" == *.test.ts ]]; then
    printf '\nTest-cost benchmark: %s\n' "$file"
    time pnpm test "$file" --maxWorkers=1
  fi
done
git diff --quiet HEAD
