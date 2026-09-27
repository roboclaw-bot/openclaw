set -euo pipefail
# Preserve native failure status while keeping measured boundaries in the CI log.
trap 'status=$?; for metric in "$RUNNER_TEMP"/harness-*.time; do if [ -f "$metric" ]; then printf "%s\n" "--- $metric ---"; cat "$metric"; fi; done; exit "$status"' EXIT
test "$BASE_SHA" = d06b334112a2fae431d2ddd5450ebc2064469317
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = ff877b04d5ed626b2d8c6dda03f7eb030792070e
test "$EXPECTED_TREE" = ff877b04d5ed626b2d8c6dda03f7eb030792070e
pnpm docs:list > "$RUNNER_TEMP/harness-docs-list.txt"
node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD --dry-run > "$RUNNER_TEMP/harness-changed-plan.txt"
cat "$RUNNER_TEMP/harness-changed-plan.txt"
# Collect every fixed target and the full static gate; no failure may reach export.
validation_status=0
test_index=0
for target in test/scripts/upgrade-survivor-legacy-worker.test.ts test/scripts/upgrade-survivor-migration-diagnostics.test.ts test/scripts/upgrade-survivor-candidate-identity.test.ts test/scripts/upgrade-survivor-worker-package.test.ts test/scripts/docker-e2e-plan.test.ts test/scripts/package-acceptance-workflow.test.ts test/scripts/docker-build-helper.test.ts test/scripts/openclaw-e2e-instance.test.ts test/scripts/upgrade-survivor-watchos-direct-node.test.ts test/scripts/prepublish-plugin-registry-shell.test.ts test/scripts/upgrade-survivor-first-hop.test.ts test/scripts/upgrade-survivor-update-result.test.ts; do
  test_index=$((test_index + 1))
  if /usr/bin/time -p -o "$RUNNER_TEMP/harness-tests-$test_index.time" pnpm test "$target"; then
    target_status=0
  else
    target_status=$?
  fi
  printf 'validation-result %s %s\n' "$target" "$target_status"
  if [ "$target_status" -ge 128 ]; then exit "$target_status"; fi
  if [ "$validation_status" -eq 0 ] && [ "$target_status" -ne 0 ]; then validation_status="$target_status"; fi
done
if /usr/bin/time -p -o "$RUNNER_TEMP/harness-checks.time" node scripts/check-changed.mjs --base "$BASE_SHA" --head HEAD; then
  check_status=0
else
  check_status=$?
fi
printf 'validation-result check-changed %s\n' "$check_status"
if [ "$check_status" -ge 128 ]; then exit "$check_status"; fi
if [ "$validation_status" -eq 0 ] && [ "$check_status" -ne 0 ]; then validation_status="$check_status"; fi
if [ "$validation_status" -ne 0 ]; then exit "$validation_status"; fi
git diff --quiet HEAD
