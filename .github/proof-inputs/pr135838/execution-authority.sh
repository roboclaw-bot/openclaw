#!/usr/bin/env bash
set -uo pipefail
# Baseline cells must exercise all three owners even when an earlier case fails.
status=0
node scripts/run-vitest.mjs run --config test/vitest/vitest.agents-core.config.ts src/agents/placement-retained-execution.behavior.test.ts
code=$?; printf "agents_exit=%s\n" "$code"; if [ "$code" -ne 0 ]; then status=1; fi
node scripts/run-vitest.mjs run --config test/vitest/vitest.gateway-core.config.ts src/gateway/worker-environments/worker-prepared-execution.behavior.test.ts
code=$?; printf "worker_exit=%s\n" "$code"; if [ "$code" -ne 0 ]; then status=1; fi
node scripts/run-vitest.mjs run --config test/vitest/vitest.gateway-core.config.ts src/gateway/worker-environments/repository-project-admission.test.ts -t "checks the existing read owner after credential revalidation"
code=$?; printf "repository_exit=%s\n" "$code"; if [ "$code" -ne 0 ]; then status=1; fi
exit "$status"
