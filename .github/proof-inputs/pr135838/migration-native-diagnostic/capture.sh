#!/usr/bin/env bash
# Hosted-only staged RED/non-reproduction capture; never a product commit or repair.
set -euo pipefail
evidence="$RUNNER_TEMP/pr159178-migration-diagnostic"
inputs="$evidence/inputs"
base=4382d0f1f29385a534fe5bdbb4e0c127ad3a1ee0
tree=586cf41cc0f20c86c1ed106823809333a2d4b0c6
test_file=src/infra/state-migrations.caller-mode.plugin-execution.test.ts
assert_source() {
  test "$(git rev-parse HEAD)" = "$base" &&
    test "$(git write-tree)" = "$tree" &&
    git diff --quiet &&
    test "$(git diff --cached --name-only "$base")" = "$test_file" &&
    git diff --cached --check &&
    sha256sum --check "$evidence/diagnostic-source.sha256"
}
case "${1:-run}" in
  materialize)
    test "$(git rev-parse HEAD)" = "$base"
    test "$(git rev-parse HEAD^{tree})" = 11a3c620dd89cdf070b28bea655fa8bdb4ca954c
    test "$(git show -s --format=%P HEAD)" = 'a23b5382c6b34f49fcfbf20d4daa03e53edaa93f fd0b54a58f93b68a49eb07695705cd770ebb91b1'
    git diff --quiet HEAD
    git diff --cached --quiet HEAD
    git show -s --format='%H%n%P%n%T' HEAD > "$evidence/source-identity.txt"
    git ls-tree -r --full-tree HEAD > "$evidence/original-full-source-git-hashes.txt"
    # Preserve complete original sources, not excerpts or only the failing assertion.
    git archive --format=tar HEAD | gzip -n > "$evidence/original-full-source.tar.gz"
    git show "HEAD:$test_file" > "$evidence/original-test.ts"
    jq -r '.sourceChecks[] | "\(.sha256)  \(.path)"' "$inputs/binding.json" > "$evidence/original-source.sha256"
    sha256sum --check "$evidence/original-source.sha256" > "$evidence/original-source-check.txt"
    git apply --index --check "$inputs/test-only-diagnostic.patch"
    git apply --index "$inputs/test-only-diagnostic.patch"
    jq -r '.sourceChecks[] | "\(.diagnosticSha256)  \(.path)"' "$inputs/binding.json" > "$evidence/diagnostic-source.sha256"
    assert_source > "$evidence/materialized-source-check.txt"
    git diff --cached --binary --full-index HEAD > "$evidence/applied-test-overlay.patch"
    git diff --cached --numstat HEAD > "$evidence/diagnostic.numstat.txt"
    cp "$test_file" "$evidence/diagnostic-test.ts"
    printf '%s\n' "$tree" > "$evidence/materialized-tree.txt"
    sha256sum "$evidence/original-full-source.tar.gz" "$evidence/original-test.ts" "$evidence/diagnostic-test.ts" > "$evidence/source-artifacts.sha256"
    exit 0
    ;;
  run) ;;
  *) exit 2 ;;
esac
assert_source > "$evidence/pre-run-source-check.txt"
test "$GITHUB_EVENT_NAME" = workflow_dispatch
test "$GITHUB_REPOSITORY" = roboclaw-bot/openclaw
test "$GITHUB_SHA" = "$WORKFLOW_SHA"
test "$RUNNER_OS" = Linux
test "$RUNNER_ARCH" = X64
test -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}${NODE_AUTH_TOKEN:-}${NPM_TOKEN:-}${NODE_OPTIONS:-}"
{ node --version; pnpm --version; bun --version; git --version; } > "$evidence/toolchain.txt"
test "$(node --version)" = v24.19.0
test "$(pnpm --version)" = 12.5.0
# Record actual capacity; a hosted runner label is not evidence of eight CPUs.
node --input-type=module -e 'import os from "node:os"; console.log(JSON.stringify({node:process.version,exe:process.execPath,platform:process.platform,arch:process.arch,logicalCpuCount:os.availableParallelism(),totalMemoryBytes:os.totalmem(),availableMemoryBytes:process.availableMemory()}))' > "$evidence/resources.json"
export OPENCLAW_VITEST_MAX_WORKERS=2
export NODE_OPTIONS=--max-old-space-size=8192
export OPENCLAW_CI_TEST_RUNTIME_POLICY=bun-compatible
export OPENCLAW_VITEST_WORKER_CACHE=1
export OPENCLAW_VITEST_FS_MODULE_CACHE_ROOT=/var/tmp/openclaw-vitest-fs-cache
export OPENCLAW_VITEST_FS_MODULE_CACHE_WRITER=0
export NODE_COMPILE_CACHE=/var/tmp/openclaw-node-compile-cache
export NODE_COMPILE_CACHE_PORTABLE=1
export OPENCLAW_NODE_COMPILE_CACHE_WRITER=0
export OPENCLAW_NODE_TEST_GROUPS_GZIP_BASE64
OPENCLAW_NODE_TEST_GROUPS_GZIP_BASE64="$(jq -r .prefixGroupsGzipBase64 "$inputs/binding.json")"
export OPENCLAW_NODE_TEST_GROUPS_JSON=''
export OPENCLAW_NODE_TEST_CONFIGS_JSON=null
export OPENCLAW_NODE_TEST_ENV_JSON=null
export OPENCLAW_NODE_TEST_INCLUDE_PATTERNS_JSON=null
export OPENCLAW_NODE_TEST_TARGETS_JSON=null
export OPENCLAW_NODE_TEST_VITEST_ARGS_JSON='[]'
export OPENCLAW_VITEST_SHARD_NAME=changed-config-compact-large-13
export OPENCLAW_VITEST_NO_OUTPUT_TIMEOUT_MS=300000
export OPENCLAW_NODE_TEST_PLAN_CONCURRENCY=1
# Refuse ambient routing overrides; do not silently edit the test environment.
test -z "${OPENCLAW_NODE_TEST_PLAN_CONTINUE_ON_FAILURE:-}${OPENCLAW_VITEST_INCLUDE_FILE:-}${OPENCLAW_VITEST_POST_SHARD_INCLUDE_FILE:-}${OPENCLAW_VITEST_FS_MODULE_CACHE_PATH:-}${OPENCLAW_VITEST_RUNTIME:-}"
python3 - <<'PY' > "$evidence/native.env.json"
import json, os
keys = [k for k in os.environ if k.startswith(('OPENCLAW_NODE_TEST_', 'OPENCLAW_VITEST_', 'OPENCLAW_NODE_COMPILE_'))]
keys += ['NODE_OPTIONS', 'NODE_COMPILE_CACHE', 'NODE_COMPILE_CACHE_PORTABLE', 'OPENCLAW_CI_TEST_RUNTIME_POLICY', 'CI', 'GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT']
print(json.dumps({k: os.environ.get(k) for k in sorted(set(keys))}, indent=2))
PY
set +e
python3 "$inputs/native-capture.py" 2>&1 | tee "$evidence/native.log"
statuses=("${PIPESTATUS[@]}")
set -e
source_status=0
assert_source > "$evidence/post-run-source-check.txt" 2>&1 || source_status=$?
printf '%s\n' "${statuses[0]}" > "$evidence/capture.exit.txt"
printf '%s\n' "${statuses[1]}" > "$evidence/tee.exit.txt"
printf '%s\n' "$source_status" > "$evidence/post-run-source-check.exit.txt"
# The real native exit remains failure. Evidence failures cannot turn a native pass green.
if (( statuses[0] != 0 )); then exit "${statuses[0]}"; fi
if (( statuses[1] != 0 )); then exit "${statuses[1]}"; fi
exit "$source_status"
