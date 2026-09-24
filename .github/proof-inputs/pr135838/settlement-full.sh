set -euo pipefail
test "$BASE_SHA" = 4f6eb26b1beda60044ee9b94cd352f37c63718e9
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
pnpm test src/gateway/session-row-placement-projection.lifecycle.test.ts src/gateway/session-row-prepared-read.test.ts src/gateway/session-row-projection.prepared-read.test.ts src/gateway/session-row-projection.accepted-facts.test.ts src/gateway/session-row-projection.incognito.test.ts src/gateway/session-row-projection.archived.test.ts src/gateway/session-row-projection.invalidation.test.ts src/gateway/session-row-projection.retention.test.ts src/gateway/session-row-projection-context.test.ts src/gateway/session-row-projection.worker-read.test.ts src/agents/harness/context-engine-turn-maintenance.test.ts src/agents/embedded-agent-runner/context-engine-maintenance.ownership.test.ts src/agents/embedded-agent-runner/context-engine-maintenance.test.ts src/agents/embedded-agent-runner/context-engine-maintenance.preparation.test.ts src/agents/embedded-agent-runner/context-engine-maintenance.lifecycle.test.ts src/agents/embedded-agent-runner/compact.foreground-resources.test.ts
TIMEFORMAT='elapsed_seconds=%3R'
for file in "${typescript[@]}"; do
  if [[ "$file" == *.test.ts ]]; then
    printf '\nTest-cost benchmark: %s\n' "$file"
    time pnpm test "$file" --maxWorkers=1
  fi
done
git diff --quiet HEAD
# Original shard-order replays and core/test types are separate required lanes on identical inputs.
