set -euo pipefail
test "$BASE_SHA" = 24c7bd68b4bb683c0f2eb55c278534d635a50403
test "$(git rev-parse HEAD^)" = "$BASE_SHA"
test "$(git rev-parse HEAD^{tree})" = "$EXPECTED_TREE"
git diff --quiet HEAD
node --input-type=module <<'WINDOWS_PROOF'
import { spawnSync } from "node:child_process";
if (process.platform !== "win32") throw new Error("Actual Windows proof requires win32");
if (process.version !== "v24.21.0") throw new Error("Windows custody proof requires Node 24.21.0");
// Full native four-case file; no Linux runIf skip counts as Windows evidence.
const file = "src/gateway/worker-environments/workspace-quiescence.windows.test.ts";
const started = performance.now();
console.log(
  "CUSTODY_PLATFORM " +
    JSON.stringify({ platform: process.platform, node: process.version, arch: process.arch }),
);
const result = spawnSync(
  process.execPath,
  [
    "--import",
    "./scripts/tsx.mjs",
    "scripts/test-projects.mts",
    file,
    "--maxWorkers=1",
    "--reporter=verbose",
    "--reporter=github-actions",
    "--reporter=./scripts/lib/vitest-resource-reporter.mts",
  ],
  { stdio: "inherit" },
);
console.log(
  "CUSTODY_PROOF " +
    JSON.stringify({
      file,
      wallSeconds: (performance.now() - started) / 1000,
      exitCode: result.status,
      signal: result.signal,
    }),
);
if (result.error) throw result.error;
process.exit(result.status ?? 1);
WINDOWS_PROOF
git diff --quiet HEAD
