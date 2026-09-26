set -euo pipefail
test "$BASE_SHA" = 76e32e92441321b2e564263bc385cc7f4cc8ecd7
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
mapfile -t changed < <(git diff --name-only "$BASE_SHA" HEAD)
./node_modules/.bin/oxfmt --check "${changed[@]}"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.core.json "${changed[@]}"
pnpm check:line-cap-ratchet --base "$BASE_SHA"
pnpm check:max-lines-ratchet --base "$BASE_SHA"
pnpm check:assertion-safety --base "$BASE_SHA"
pnpm check:env-var-count --base "$BASE_SHA"
pnpm test src/gateway/worker-environments/session-repository-checkpoints.test.ts src/gateway/worker-environments/workspace-result-repository.test.ts
pnpm tsgo:core
git diff --quiet HEAD
# Existing matched red/green and source review are retained. Exact-head PR CI
# owns the remaining test-type and sibling gates after this mechanical rebase.
