set -euo pipefail
test "$BASE_SHA" = 1844d933b2dc10673db973608d5d4d9bd0ca9105
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD

# One canonical invocation per file: explicit-target runs stop after a failed shard.
# Keep native Vitest results unchanged and finish all files before returning failure.
trap 'exit 130' INT
trap 'exit 143' TERM
aggregate=0
completed=0
for file in \
  src/gateway/worker-environments/provider-invocation.test.ts \
  extensions/crabbox/src/crabbox-worker-allocation-authority.test.ts \
  extensions/crabbox/src/crabbox-worker-provision-commands.test.ts
do
  printf 'PROVIDER_FILE_BEGIN file=%s\n' "$file"
  code=0
  if /usr/bin/time -f "DELEGATION_PROOF file=$file wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x" \
    pnpm test "$file" --maxWorkers=1 --reporter=verbose --reporter=github-actions --reporter=./scripts/lib/vitest-resource-reporter.mts
  then
    code=0
  else
    code=$?
  fi
  printf 'PROVIDER_FILE_END file=%s exit=%s\n' "$file" "$code"
  completed=$((completed + 1))
  if [ "$aggregate" -eq 0 ] && [ "$code" -ne 0 ]; then
    aggregate=$code
  fi
  # Respect process termination; never schedule fresh files after cancellation.
  if [ "$code" -ge 128 ]; then
    exit "$code"
  fi
done
test "$completed" -eq 3
git diff --quiet HEAD
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
printf 'PROVIDER_FILE_AGGREGATE completed=%s exit=%s\n' "$completed" "$aggregate"
exit "$aggregate"
