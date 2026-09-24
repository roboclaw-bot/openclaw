import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const proof = path.dirname(fileURLToPath(import.meta.url));
const manifest = JSON.parse(fs.readFileSync(path.join(proof, "manifest.json"), "utf8"));
const inputs = JSON.parse(fs.readFileSync(path.join(proof, "dependency-inputs.json"), "utf8"));
const root = process.cwd();
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");
const git = (...args) => execFileSync("git", args, { encoding: "utf8" }).trim();
const invoke = (command, args) => execFileSync(command, args, { stdio: "inherit" });
const load = (name) => import(pathToFileURL(path.join(root, name)).href);
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + "\n");
assert.equal(process.version, manifest.node);
assert.equal(process.platform, "linux");
assert.equal(process.arch, "x64");
assert.equal(git("rev-parse", "HEAD"), manifest.source);
assert.equal(git("rev-parse", "HEAD^"), manifest.base);
assert.equal(git("rev-parse", "HEAD^{tree}"), manifest.tree);
assert.equal(process.env.GIT_COMMIT, manifest.source);
assert.equal(process.env.OPENCLAW_BUILD_TIMESTAMP, manifest.buildTimestamp);
assert.equal(
  JSON.parse(fs.readFileSync("package.json", "utf8")).packageManager,
  manifest.packageManager,
);
assert.equal(execFileSync("pnpm", ["--version"], { encoding: "utf8" }).trim(), "12.4.2");
assert.equal(
  sha(
    execFileSync("git", [
      "diff",
      "--no-ext-diff",
      "--no-textconv",
      "--full-index",
      "--binary",
      "HEAD^",
      "HEAD",
    ]),
  ),
  manifest.patch,
);
for (const [name, record] of Object.entries(inputs)) {
  assert(!path.isAbsolute(name) && !name.split("/").includes(".."));
  if (record.missing === true) {
    assert.equal(
      fs.lstatSync(name, { throwIfNoEntry: false }),
      undefined,
      "Dependency input must remain absent: " + name,
    );
  } else {
    assert.equal(sha(fs.readFileSync(name)), record.sha256, "Dependency input changed: " + name);
  }
}
assert.equal(Object.keys(inputs).length, 229);
assert.notEqual(process.env.OPENCLAW_RUN_NODE_SKIP_DTS_BUILD, "1");
assert.notEqual(process.env.OPENCLAW_UPDATE_IN_PROGRESS, "1");
assert.notEqual(process.env.OPENCLAW_BUILD_CACHE, "0");
assert(!process.env.OPENCLAW_BUILD_PRIVATE_QA || process.env.OPENCLAW_BUILD_PRIVATE_QA === "0");
assert(!process.env.BUILD_ALL_CACHE_ROOT, "Use the canonical checkout cache root");
const { BUNDLED_PLUGIN_BUILD_ENV_NAMES } = await load(
  "scripts/lib/bundled-plugin-build-entries.mjs",
);
for (const name of BUNDLED_PLUGIN_BUILD_ENV_NAMES)
  assert(!process.env[name], "Narrowed build selector: " + name);
invoke("git", ["diff", "--quiet", "HEAD"]);
const cacheRoot = path.join(root, ".artifacts/build-all-cache");
const artifact = path.join(proof, "out");
const phase = process.argv[2];
const packageLabels = ["tsdown-ai", "tsdown-packages"];
const compilerLabels = [
  ...packageLabels,
  "tsdown-unified-openclaw-dts-base",
  ...[1, 2, 3, 4, 5].map((n) => "tsdown-unified-openclaw-dts-extensions-" + n),
  "tsdown-plugin-sdk-openclaw-dts-plugin-sdk-1",
  "tsdown-plugin-sdk-openclaw-dts-plugin-sdk-2",
];
const provenance = {
  controller: process.env.GITHUB_SHA,
  run: process.env.GITHUB_RUN_ID,
  attempt: process.env.GITHUB_RUN_ATTEMPT,
  job: process.env.GITHUB_JOB,
  node: process.version,
  platform: process.platform,
  arch: process.arch,
};

function inventory(directory) {
  const files = {};
  function visit(current, prefix = "") {
    const stat = fs.lstatSync(current);
    assert(stat.isDirectory() && !stat.isSymbolicLink());
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      assert(
        !entry.name.includes(".lock") && !entry.name.endsWith(".tmp") && entry.name !== "unjoined",
      );
      const relative = prefix ? prefix + "/" + entry.name : entry.name;
      const file = path.join(current, entry.name);
      const child = fs.lstatSync(file);
      assert(!child.isSymbolicLink(), "Cache handoff forbids symlinks");
      if (child.isDirectory()) visit(file, relative);
      else {
        assert(child.isFile());
        files[relative] = sha(fs.readFileSync(file));
      }
    }
  }
  visit(directory);
  return files;
}
function validateGeneration(directory, label) {
  const files = inventory(directory);
  const stamp = JSON.parse(fs.readFileSync(path.join(directory, "stamp.json"), "utf8"));
  assert.equal(stamp.version, 6);
  assert.match(stamp.signature, /^[a-f0-9]{64}$/);
  const expected = { "stamp.json": sha(fs.readFileSync(path.join(directory, "stamp.json"))) };
  for (const [name, digest] of Object.entries(stamp.outputs)) {
    assert(!path.isAbsolute(name) && !name.split(/[\\/]/).includes(".."));
    assert.match(digest, /^[a-f0-9]{64}$/);
    if (packageLabels.includes(label)) {
      assert(name.startsWith("packages/") && /\.d\.(?:ts|mts|cts)$/.test(name));
    } else {
      assert(
        (name.startsWith("dist/") && /\.d\.(?:ts|mts|cts)$/.test(name)) ||
          (name.startsWith("compiler-inputs/") && name.endsWith(".json")),
      );
    }
    expected["outputs/" + name] = digest;
  }
  assert(Object.keys(expected).length > 1);
  assert.deepEqual(files, expected, "Incomplete or extra canonical cache files: " + label);
  return files;
}

if (phase === "restore") {
  const expectedPhase = process.argv[3];
  assert(["warm", "full"].includes(expectedPhase));
  const carry = path.join(proof, "carry");
  const receipt = JSON.parse(fs.readFileSync(path.join(carry, "receipt.json"), "utf8"));
  assert.equal(receipt.phase, expectedPhase);
  assert.equal(receipt.completed, true);
  assert.deepEqual(receipt.identity, manifest);
  assert.equal(receipt.provenance.controller, provenance.controller);
  assert.equal(receipt.provenance.run, provenance.run);
  assert.equal(receipt.provenance.attempt, process.env.PRODUCER_ATTEMPT);
  assert.equal(receipt.provenance.job, expectedPhase);
  const labels = expectedPhase === "warm" ? packageLabels : compilerLabels;
  assert.deepEqual(receipt.labels, labels);
  assert.deepEqual(inventory(path.join(carry, "cache")), receipt.files);
  if (fs.existsSync(cacheRoot)) inventory(cacheRoot);
  fs.mkdirSync(path.dirname(cacheRoot), { recursive: true });
  assert(!fs.lstatSync(path.dirname(cacheRoot)).isSymbolicLink());
  for (const label of labels) {
    validateGeneration(path.join(carry, "cache", label), label);
    fs.cpSync(path.join(carry, "cache", label), path.join(cacheRoot, label), { recursive: true });
    validateGeneration(path.join(cacheRoot, label), label);
  }
  writeJson(path.join(proof, "predecessor.json"), {
    phase: expectedPhase,
    artifactId: process.env.PRODUCER_ARTIFACT,
    artifactDigest: process.env.PRODUCER_DIGEST,
    attempt: process.env.PRODUCER_ATTEMPT,
    receiptSha256: sha(fs.readFileSync(path.join(carry, "receipt.json"))),
  });
  console.log(
    "Restored successful " + expectedPhase + " cache; native signatures still govern reuse.",
  );
} else {
  assert(["warm", "full", "sdk"].includes(phase));
  const { resolveBuildAllSteps, runBuildAllSteps } = await load("scripts/build-all.mts");
  const { resolveBuildStepCacheState } = await load("scripts/lib/build-artifact-cache.mts");
  const { withDistArtifactOwnership, resolveDistArtifactLockPath } = await load(
    "scripts/lib/dist-artifact-ownership.mts",
  );
  fs.mkdirSync(artifact, { recursive: true });
  let timings;
  if (phase === "warm") {
    const all = resolveBuildAllSteps("full");
    const steps = all.slice(0, all.findIndex((step) => step.label === "tsdown-packages") + 1);
    assert.deepEqual(
      steps.map((step) => step.label),
      ["plugins:assets:build", ...packageLabels],
    );
    const result = await withDistArtifactOwnership(root, () => runBuildAllSteps("full", { steps }));
    assert.equal(result.exitCode, 0);
    assert.deepEqual(
      result.timings.map((step) => step.label),
      steps.map((step) => step.label),
    );
    timings = result.timings;
  } else {
    for (const label of packageLabels) {
      const step = resolveBuildAllSteps("full").find((entry) => entry.label === label);
      assert(step);
      const state = resolveBuildStepCacheState(step);
      assert(
        state.fresh,
        "Required canonical cache is not reusable: " + label + " / " + state.reason,
      );
    }
    if (phase === "full") invoke("pnpm", ["build"]);
    else {
      invoke("pnpm", ["plugin-sdk:check-exports"]);
      invoke("pnpm", ["plugin-sdk:surface:check"]);
      invoke("pnpm", [
        "plugin-sdk:api:diff",
        "--base",
        manifest.base,
        "--head",
        manifest.source,
        "--json",
        path.join(artifact, "candidate-sdk-api.json"),
        "--summary",
        path.join(artifact, "candidate-sdk-api.txt"),
      ]);
      invoke("pnpm", ["plugins:assets:build"]);
      invoke("pnpm", ["build:plugin-sdk:strict-smoke"]);
    }
  }
  const lock = resolveDistArtifactLockPath(root);
  assert(!fs.existsSync(lock) || fs.readdirSync(lock).length === 0, "Dist custody did not settle");
  invoke("git", ["diff", "--quiet", "HEAD"]);
  const receipt = {
    phase,
    identity: manifest,
    provenance,
    timings,
    completed: true,
    predecessor:
      phase === "warm"
        ? null
        : JSON.parse(fs.readFileSync(path.join(proof, "predecessor.json"), "utf8")),
  };
  if (phase !== "sdk") {
    const labels = phase === "warm" ? packageLabels : compilerLabels;
    for (const label of labels) {
      validateGeneration(path.join(cacheRoot, label), label);
      fs.cpSync(path.join(cacheRoot, label), path.join(artifact, "cache", label), {
        recursive: true,
      });
    }
    receipt.labels = labels;
    receipt.files = inventory(path.join(artifact, "cache"));
  } else {
    const report = path.join(artifact, "candidate-sdk-api.json");
    JSON.parse(fs.readFileSync(report, "utf8"));
    assert(fs.statSync(path.join(artifact, "candidate-sdk-api.txt")).size > 0);
    receipt.compatibilityReview = {
      status: "required",
      reportSha256: sha(fs.readFileSync(report)),
    };
  }
  writeJson(path.join(artifact, "receipt.json"), receipt);
}
