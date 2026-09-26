set -euo pipefail
test "$BASE_SHA" = 9e323ad891f776e1645ed494866aa8bdefe8362c
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --check "$BASE_SHA" HEAD
# Scanner fixture and its gateway graph already passed on byte-identical sources.
node scripts/check-changed.mjs --dry-run -- scripts/pr-lib/wrapper-components.txt
pnpm test test/scripts/eager-import-closure.test.ts test/scripts/pr-wrapper-source-closure.test.ts test/scripts/pr-worktree-provision.test.ts test/scripts/pr-wrappers.test.ts
git diff --quiet HEAD
