set -euo pipefail
test "$BASE_SHA" = 24c7bd68b4bb683c0f2eb55c278534d635a50403
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD
# Separate canonical invocations: a failed first project must not suppress the other file.
trap 'exit 130' INT
trap 'exit 143' TERM
aggregate=0
for file in src/gateway/worker-environments/workspace-result-repository.test.ts src/gateway/worker-environments/workspace-quiescence.test.ts; do
  code=0
  /usr/bin/time -f "CUSTODY_PROOF file=$file wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x" pnpm test "$file" --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts || code=$?
  printf 'CUSTODY_FILE_END file=%s exit=%s\n' "$file" "$code"
  if [ "$aggregate" -eq 0 ] && [ "$code" -ne 0 ]; then aggregate=$code; fi
  if [ "$code" -ge 128 ]; then exit "$code"; fi
done
git diff --quiet HEAD
exit "$aggregate"
