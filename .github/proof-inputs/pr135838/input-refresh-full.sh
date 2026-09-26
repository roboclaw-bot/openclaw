set -euo pipefail
test "$BASE_SHA" = 8be6c5adf3f7b76a52278800e4f75ec9f36c1720
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
mapfile -t changed_files < <(git diff --name-only "$BASE_SHA" HEAD)
mapfile -t typescript < <(git diff --name-only "$BASE_SHA" HEAD -- '*.ts')
git diff --check "$BASE_SHA" HEAD
node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD --dry-run
./node_modules/.bin/oxfmt --check "${changed_files[@]}"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json "${typescript[@]}"
pnpm check:line-cap-ratchet --base "$BASE_SHA"
pnpm check:max-lines-ratchet --base "$BASE_SHA"
pnpm check:assertion-safety --base "$BASE_SHA"
pnpm check:env-var-count --base "$BASE_SHA"
pnpm test src/gateway/server.agent-runtime-authority-proof.test.ts
pnpm test src/gateway/agent-turn/agent-run-user-turn.test.ts src/gateway/server-methods/agent.test.ts src/gateway/server-methods/agent-run-local-operator-authority.test.ts src/gateway/agent-turn/internal-facade.test.ts src/gateway/agent-turn/agent-wait-dedupe.test.ts src/gateway/agent-turn/agent-run-dispatch.owner.test.ts src/gateway/agent-turn/agent-run-dispatch.sqlite.test.ts src/gateway/agent-turn/agent-run-dispatch.legacy.test.ts
pnpm test src/gateway/server.agent-input-authority.test.ts src/gateway/server.agent-late-admission.test.ts src/gateway/agent-turn/agent-run-execution-phase.owner.test.ts src/gateway/agent-turn/agent-run-task-tracking.test.ts
git diff --quiet HEAD
