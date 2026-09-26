#!/usr/bin/env bash
set -euo pipefail
file=src/skills/runtime/session-snapshot.integration.test.ts
git diff --check "$BASE_SHA" HEAD
./node_modules/.bin/oxfmt --check "$file"
node scripts/run-oxlint.mjs --tsconfig config/tsconfig/oxlint.json "$file"
node scripts/run-tsgo.mjs --project test/tsconfig/tsconfig.core.test.services.json --noEmit
# Preserve the recorded group input, ordering, worker budget, and native failure handling.
export OPENCLAW_NODE_TEST_GROUPS_JSON="$(cat "$RUNNER_TEMP/transport-ci-original-groups.json")"
export OPENCLAW_NODE_TEST_GROUPS_GZIP_BASE64=""
export OPENCLAW_NODE_TEST_CONFIGS_JSON=null OPENCLAW_NODE_TEST_ENV_JSON=null
export OPENCLAW_NODE_TEST_INCLUDE_PATTERNS_JSON=null OPENCLAW_NODE_TEST_TARGETS_JSON=null
export OPENCLAW_NODE_TEST_VITEST_ARGS_JSON='[]'
export OPENCLAW_VITEST_SHARD_NAME=changed-config-compact-large-27
export OPENCLAW_VITEST_MAX_WORKERS=2 OPENCLAW_NODE_TEST_PLAN_CONCURRENCY=1
export OPENCLAW_CI_TEST_RUNTIME_POLICY=bun-compatible FROZEN_TARGET=false
export OPENCLAW_VITEST_NO_OUTPUT_TIMEOUT_MS=300000 OPENCLAW_VITEST_WORKER_CACHE=1
export NODE_OPTIONS=--max-old-space-size=8192
# Hosted hardware/cold caches differ from the originating public Blacksmith job.
time -p node --import tsx scripts/ci-run-node-test-shard.mts
# Measure the changed fixture separately after the original-order regression has passed.
unset OPENCLAW_NODE_TEST_GROUPS_JSON OPENCLAW_NODE_TEST_GROUPS_GZIP_BASE64
/usr/bin/time -f 'FIXTURE_PROOF wall_s=%e user_s=%U sys_s=%S maxrss_kib=%M exit=%x' pnpm test "$file" --maxWorkers=1
