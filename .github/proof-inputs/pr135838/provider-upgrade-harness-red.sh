set -euo pipefail
# Preserve native failure status while keeping measured boundaries in the CI log.
trap 'status=$?; for metric in "$RUNNER_TEMP"/harness-*.time; do if [ -f "$metric" ]; then printf "%s\n" "--- $metric ---"; cat "$metric"; fi; done; exit "$status"' EXIT
test "$BASE_SHA" = d06b334112a2fae431d2ddd5450ebc2064469317
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = 1c6d2d6a440e1a3bf44f8b26c71b2e1324d06c75
test "$EXPECTED_TREE" = 1c6d2d6a440e1a3bf44f8b26c71b2e1324d06c75
test "$(sha256sum "$RUNNER_TEMP/harness-regression-owners.patch" | cut -d " " -f1)" = ac56233c0d104d52650885813fb9f0be397211a7ac7f04f2afcda85538f90456
git apply --check "$RUNNER_TEMP/harness-regression-owners.patch"
git apply "$RUNNER_TEMP/harness-regression-owners.patch"
test "$(git hash-object scripts/e2e/lib/upgrade-survivor/run.sh)" = 52fd2cc4518f73e3e387d2a193bb64c72710c694
test "$(git hash-object scripts/e2e/lib/upgrade-survivor/worker-cell-package.mjs)" = 1272a4be72dd1b7004b733c239a8c609bdab4797
test "$(git hash-object scripts/lib/openclaw-e2e-instance.sh)" = 0911557bd4d0acb19bfc6780a979f8b87ff491cf
# Keep repaired tests and the parseable fixture; restore only the reviewed-v1
# cleanup/payload/readiness owners. Native Vitest failure is the RED result.
/usr/bin/time -p -o "$RUNNER_TEMP/harness-regression.time" pnpm test test/scripts/upgrade-survivor-migration-diagnostics.test.ts test/scripts/upgrade-survivor-candidate-identity.test.ts -t 'publishes the first failure once|refuses (stale-root-helper|pending-lifecycle) at the actual candidate boundary'
echo "Regression control unexpectedly passed; not behavioral RED evidence" >&2
exit 2
