#!/usr/bin/env bash
set -euo pipefail
node scripts/run-vitest.mjs run --config test/vitest/vitest.gateway-core.config.ts src/gateway/worker-environments/workspace-result-repository.test.ts -t "slice6 lifecycle:"
