// Proof-only driver. Run in isolated CI, once per source revision/process.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [mode, stateArgument, label] = process.argv.slice(2);
assert.ok(mode === "produce" || mode === "consume");
assert.ok(stateArgument && label);
const stateRoot = path.resolve(stateArgument);
const sourceRoot = process.cwd();
const source = (file) => import(pathToFileURL(path.join(sourceRoot, file)).href);
const { openOpenClawStateDatabase } = await source("src/state/openclaw-state-db.ts");
const { closeOpenClawStateDatabaseByPathAsync } = await source(
  "src/state/openclaw-state-db-cache.ts",
);
const { createSessionRepositoryWorkspaceStore } = await source(
  "src/state/session-repository-workspaces.ts",
);
const { drainGlobalSingletonLifecycleState } = await source("src/shared/global-singleton.ts");
const { requireWorkspaceResultGit: git } = await source(
  "src/gateway/worker-environments/workspace-result-git.ts",
);
const { readActualWorkspaceManifest } = await source(
  "src/gateway/worker-environments/workspace-reconcile-core.ts",
);
const { serializeWorkerWorkspaceManifest } = await source(
  "src/gateway/worker-environments/workspace-manifest.ts",
);
const { stageSessionRepositoryCheckpoint, withSessionRepositoryCheckpoint } = await source(
  "src/gateway/worker-environments/session-repository-checkpoints.ts",
);
const {
  REMOTE_GITHUB_PUBLICATION_SNAPSHOT_JS,
  readGitHubRepositoryPublicationMetadata,
  readGitHubRepositoryPublicationBlob,
} = await source("src/gateway/github-repository-publication-snapshot.ts");
const { runCommandWithTimeout } = await source("src/process/exec.ts");
const databasePath = path.join(stateRoot, "openclaw.sqlite");
const receiptPath = path.join(stateRoot, "proof-receipt.json");
const rawContent = "checkpoint roundtrip\r\n";
const normalizedContent = "checkpoint roundtrip\n";
const scriptContent = "#!/bin/sh\nprintf 'checkpoint proof\\n'\n";
// This cell measures persisted compatibility, not authority lifetime; the separate
// production mutation scenario owns real placement-drain evidence.
const assertCurrent = () => {};
let database;

function schema() {
  // Schema introspection only; all application reads/writes use production owners.
  const objects = database.db
    .prepare(
      "SELECT type, name, tbl_name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
    )
    .all();
  const version = Number(database.db.prepare("PRAGMA user_version").get().user_version);
  assert.ok(Number.isSafeInteger(version));
  return { version, digest: createHash("sha256").update(JSON.stringify(objects)).digest("hex") };
}

async function verify(store, saved) {
  assert.equal(saved.fixture, "pr150611-checkpoint-compat-v1");
  assert.deepEqual(store.get(saved.workspace.workspaceId), saved.workspace);
  assert.deepEqual(schema(), saved.schema);
  let reads = 0;
  await withSessionRepositoryCheckpoint(
    { store, workspaceId: saved.workspace.workspaceId, includePublication: true },
    async (snapshot) => {
      reads += 1;
      assert.equal(snapshot.base.version, 1);
      assert.equal(snapshot.current.version, 1);
      assert.equal(snapshot.baseManifestRef, saved.workspace.baseManifestHash);
      assert.equal(snapshot.currentManifestRef, saved.workspace.manifestHash);
      assert.equal(
        await fs.readFile(path.join(snapshot.stagingRoot, "changed.txt"), "utf8"),
        rawContent,
      );
      assert.equal(
        await fs.readFile(path.join(snapshot.stagingRoot, "proof.sh"), "utf8"),
        scriptContent,
      );
      assert.equal(
        (await fs.stat(path.join(snapshot.stagingRoot, "proof.sh"))).mode & 0o111,
        0o111,
      );
      assert.equal(await fs.readlink(path.join(snapshot.stagingRoot, "alias.txt")), "changed.txt");
      assert.ok(snapshot.base.entries.some((entry) => entry.path === "removed.txt"));
      assert.ok(!snapshot.current.entries.some((entry) => entry.path === "removed.txt"));
      assert.ok(snapshot.publicationStagingRoot && snapshot.publicationDigest);
      assert.equal(snapshot.publicationDigest, saved.publicationDigest);
      const { snapshot: publication } = await readGitHubRepositoryPublicationMetadata(
        snapshot.publicationStagingRoot,
        snapshot.publicationDigest,
      );
      assert.equal(publication.version, 1);
      assert.equal(publication.baseCommit, saved.workspace.baseCommit);
      const changed = publication.entries.find((entry) => entry.path === "changed.txt");
      assert.ok(changed?.sha);
      assert.equal(
        (
          await readGitHubRepositoryPublicationBlob(snapshot.publicationStagingRoot, changed.sha)
        ).toString("utf8"),
        normalizedContent,
      );
      assert.equal(publication.entries.find((entry) => entry.path === "removed.txt")?.sha, null);
      assert.equal(publication.entries.find((entry) => entry.path === "proof.sh")?.mode, "100755");
      assert.equal(publication.entries.find((entry) => entry.path === "alias.txt")?.mode, "120000");
    },
  );
  assert.equal(reads, 1);
  assert.equal(
    await git(store.artifactPath(saved.workspace.workspaceId), [
      "for-each-ref",
      "--format=%(refname)",
      "refs/openclaw/worker-result-candidates/",
    ]),
    "",
  );
  assert.deepEqual(store.get(saved.workspace.workspaceId), saved.workspace);
  assert.deepEqual(schema(), saved.schema);
  return {
    rawBytes: true,
    normalizedPublication: true,
    deletion: true,
    executableMode: true,
    symlink: true,
    acceptedRowUnchanged: true,
    schemaUnchanged: true,
    candidateRefs: 0,
  };
}

try {
  if (mode === "produce") {
    // Fresh directory is mandatory; never overwrite a prior cell's data.
    await fs.mkdir(stateRoot);
    database = openOpenClawStateDatabase({ path: databasePath });
    const store = createSessionRepositoryWorkspaceStore({ database });
    const remote = path.join(stateRoot, "source");
    await fs.mkdir(remote);
    await fs.writeFile(path.join(remote, ".gitattributes"), "changed.txt text eol=lf\n");
    await fs.writeFile(path.join(remote, "changed.txt"), "base\n");
    await fs.writeFile(path.join(remote, "removed.txt"), "remove after base\n");
    await git(remote, ["init", "--quiet"]);
    await git(remote, ["add", "."]);
    await git(remote, [
      "-c",
      "user.name=Checkpoint Proof",
      "-c",
      "user.email=checkpoint@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      "base",
    ]);
    const baseCommit = await git(remote, ["rev-parse", "HEAD"]);
    const base = await readActualWorkspaceManifest({ root: remote, baseCommit });
    await fs.writeFile(path.join(remote, "changed.txt"), rawContent);
    await fs.rm(path.join(remote, "removed.txt"));
    await fs.writeFile(path.join(remote, "proof.sh"), scriptContent, { mode: 0o755 });
    await fs.symlink("changed.txt", path.join(remote, "alias.txt"));
    const current = await readActualWorkspaceManifest({ root: remote, baseCommit });
    const publicationStagingRoot = path.join(stateRoot, "publication");
    const capture = await runCommandWithTimeout(
      [
        process.execPath,
        "-e",
        REMOTE_GITHUB_PUBLICATION_SNAPSHOT_JS,
        remote,
        baseCommit,
        publicationStagingRoot,
      ],
      { timeoutMs: 60_000, maxOutputBytes: 64 * 1024 },
    );
    assert.equal(capture.termination, "exit");
    assert.equal(capture.code, 0, capture.stderr);
    const publicationDigest = capture.stdout.trim();
    assert.match(publicationDigest, /^sha256:[a-f0-9]{64}$/u);
    const initial = store.create({
      agentId: "main",
      sessionKey: "agent:main:checkpoint-compat",
      url: "https://example.invalid/checkpoint-proof.git",
      assertCurrent,
    });
    const workspace = store.bindBase({
      workspaceId: initial.workspaceId,
      expectedRevision: initial.revision,
      baseCommit,
      baseManifestHash: base.manifestRef,
      assertCurrent,
    });
    const prepared = await stageSessionRepositoryCheckpoint({
      store,
      workspaceId: workspace.workspaceId,
      expectedRevision: workspace.revision,
      checkpointRef: "refs/openclaw/worker-results/compatibility-cell",
      stagingRoot: remote,
      baseManifestRaw: serializeWorkerWorkspaceManifest(base.manifest),
      currentManifestRaw: serializeWorkerWorkspaceManifest(current.manifest),
      baseManifestRef: base.manifestRef,
      currentManifestRef: current.manifestRef,
      publicationStagingRoot,
      publicationDigest,
      assertCurrent,
    });
    let accepted;
    try {
      accepted = await prepared.publish();
    } finally {
      await prepared.discard();
    }
    const saved = {
      fixture: "pr150611-checkpoint-compat-v1",
      producer: label,
      workspace: accepted,
      publicationDigest,
      schema: schema(),
    };
    await fs.writeFile(receiptPath, JSON.stringify(saved), { mode: 0o600, flag: "wx" });
    const checks = await verify(store, saved);
    console.log(
      JSON.stringify({
        proof: "checkpoint-compatibility",
        mode,
        label,
        sourceCommit: await git(sourceRoot, ["rev-parse", "HEAD"]),
        ...checks,
      }),
    );
  } else {
    // The receiving source revision/process opens the producer's existing DB and Git refs.
    const saved = JSON.parse(await fs.readFile(receiptPath, "utf8"));
    database = openOpenClawStateDatabase({ path: databasePath });
    const store = createSessionRepositoryWorkspaceStore({ database });
    const checks = await verify(store, saved);
    console.log(
      JSON.stringify({
        proof: "checkpoint-compatibility",
        mode,
        label,
        producer: saved.producer,
        sourceCommit: await git(sourceRoot, ["rev-parse", "HEAD"]),
        ...checks,
      }),
    );
  }
} finally {
  await drainGlobalSingletonLifecycleState("close");
  if (database) await closeOpenClawStateDatabaseByPathAsync(databasePath);
}
