set -euo pipefail
# Preserve native failure status while keeping measured boundaries in the CI log.
trap 'status=$?; for metric in "$RUNNER_TEMP"/harness-*.time; do if [ -f "$metric" ]; then printf "%s\n" "--- $metric ---"; cat "$metric"; fi; done; exit "$status"' EXIT
test "$BASE_SHA" = d06b334112a2fae431d2ddd5450ebc2064469317
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = 573f2a33d848062bb9940f98479fe22c0b6c65b7
test "$EXPECTED_TREE" = 573f2a33d848062bb9940f98479fe22c0b6c65b7
pnpm docs:list > "$RUNNER_TEMP/harness-docs-list.txt"
node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD --dry-run > "$RUNNER_TEMP/harness-changed-plan.txt"
cat "$RUNNER_TEMP/harness-changed-plan.txt"
# Exercise the eleven behavioral files before the broader static gate; both must pass.
/usr/bin/time -p -o "$RUNNER_TEMP/harness-tests.time" pnpm test test/scripts/upgrade-survivor-legacy-worker.test.ts test/scripts/upgrade-survivor-migration-diagnostics.test.ts test/scripts/upgrade-survivor-candidate-identity.test.ts test/scripts/upgrade-survivor-worker-package.test.ts test/scripts/docker-e2e-plan.test.ts test/scripts/package-acceptance-workflow.test.ts test/scripts/docker-build-helper.test.ts test/scripts/openclaw-e2e-instance.test.ts test/scripts/upgrade-survivor-watchos-direct-node.test.ts test/scripts/prepublish-plugin-registry-shell.test.ts test/scripts/upgrade-survivor-first-hop.test.ts
/usr/bin/time -p -o "$RUNNER_TEMP/harness-checks.time" node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD
git diff --quiet HEAD
