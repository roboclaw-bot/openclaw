import fs from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createDeferred } from "../../../test/helpers/promise.js";
import { useAutoCleanupTempDirTracker } from "../../../test/helpers/temp-dir.js";
import { createNodeWorkerTunnelManager } from "./node-worker-tunnel.js";
import {
  environment,
  startRequest,
  transport,
  workspaceTransfer,
} from "./node-worker-tunnel.test-support.js";
import { createNodeWorkspaceTransferService } from "./node-workspace-transfer-service.js";
import { createWorkerTunnelManager } from "./tunnel.js";
import { SSH, PWD_COMMAND, fakeRunner, resolveIdentity, success } from "./tunnel.test-support.js";

const tempDirs = useAutoCleanupTempDirTracker(afterEach);
afterEach(() => vi.restoreAllMocks());

// These requests use structural typing so this exact test runs against the parent
// that ignores initiating authority and the candidate that consumes it. No new
// production helper, SDK symbol, or async-revoke contract is needed for red proof.
describe("transport initiating source behavioral proof", () => {
  it("revokes the initiating download without revoking retained workspace custody", async () => {
    const root = tempDirs.make("transport-source-custody-");
    const localPath = path.join(root, "workspace");
    await fs.mkdir(localPath);
    await fs.writeFile(path.join(localPath, "input.txt"), "input\n");
    const record = environment();
    const owner = new AbortController();
    const service = createNodeWorkspaceTransferService({
      temporaryRoot: path.join(root, "transfers"),
      getOwner: () => ({
        environment: record,
        credential: { ownerEpoch: record.ownerEpoch, sessionId: "session-1" },
      }),
    });
    let current = true;
    const request = {
      environmentId: record.environmentId,
      ownerEpoch: record.ownerEpoch,
      sessionId: "session-1",
      generation: record.ownerEpoch,
      localPath,
      signal: owner.signal,
      isAuthorized: () => true,
      authorize: () => {
        if (!current) throw new Error("initiating source closed");
      },
    };
    try {
      const prepared = await service.prepareSync(request);
      const route = {
        kind: "manifest",
        direction: "download",
        environmentId: record.environmentId,
        manifestRef: prepared.snapshot.manifestRef,
      } as const;
      expect(service.authorize({ token: prepared.token, route })).toBeDefined();
      current = false;
      expect.soft(service.authorize({ token: prepared.token, route })).toBeUndefined();
      expect(owner.signal.aborted).toBe(false);
      const upload = service.prepareUpload(record.environmentId, prepared.snapshot.manifestRef);
      expect(upload).toBeTruthy();
      await service.revoke(record.environmentId, upload);
    } finally {
      await service.closeAll();
    }
  });

  it("rejects a revoked SSH joiner without retiring the established tunnel", async () => {
    const identity = createDeferred<Awaited<ReturnType<typeof resolveIdentity>>>();
    const entered = createDeferred();
    const fake = fakeRunner();
    const manager = createWorkerTunnelManager({ runner: fake.runner });
    const request = {
      environmentId: "worker:source-proof",
      ownerEpoch: 1,
      bundleHash: "a".repeat(64),
      ssh: SSH,
      resolveIdentity: () => {
        entered.resolve();
        return identity.promise;
      },
    };
    const first = manager.start(request);
    let current = true;
    const closed = new Error("initiating source closed");
    try {
      await entered.promise;
      const joiningRequest = {
        ...request,
        authorize: () => {
          if (!current) throw closed;
        },
      };
      const joining = manager.start(joiningRequest).then(
        () => undefined,
        (error: unknown) => error,
      );
      current = false;
      identity.resolve(await resolveIdentity());
      const handle = await first;
      expect.soft(await joining).toBe(closed);
      expect(manager.status(request.environmentId)).toBe("connected");
      await expect(handle.runWorkspaceCommand(PWD_COMMAND)).resolves.toEqual(success());
    } finally {
      identity.resolve(await resolveIdentity());
      await first.catch(() => undefined);
      await manager.stopAll();
    }
  });

  it("rejects node startup when its source closes during workspace binding", async () => {
    const record = environment();
    const binding = createDeferred<undefined>();
    const entered = createDeferred();
    const transfer = workspaceTransfer();
    const manager = createNodeWorkerTunnelManager({
      gatewayDeviceId: "gateway-device-1",
      getEnvironment: () => record,
      listEnvironments: () => [record],
      getTransport: transport,
      launchNodeWorker: vi.fn(),
      validateWorkerTurn: () => true,
      workspaceTransfer: transfer,
    });
    manager.bindWorkspaceBindingResolver(async () => {
      entered.resolve();
      return await binding.promise;
    });
    let current = true;
    const closed = new Error("initiating source closed");
    const request = {
      ...startRequest(),
      authorize: () => {
        if (!current) throw closed;
      },
    };
    const starting = manager.start(request).then(
      () => undefined,
      (error: unknown) => error,
    );
    try {
      await entered.promise;
      current = false;
      binding.resolve(undefined);
      expect.soft(await starting).toBe(closed);
      expect(manager.status(record.environmentId)).toBe("stopped");
    } finally {
      binding.resolve(undefined);
      await starting;
      await manager.stop(record.environmentId);
    }
  });

  it.each(["local", "repository"] as const)(
    "does not let a queued revoked %s replacement retire its predecessor",
    async (source) => {
      const root = tempDirs.make("transport-source-queue-");
      const localPath = path.join(root, "workspace");
      await fs.mkdir(localPath);
      await fs.writeFile(path.join(localPath, "input.txt"), "input\n");
      const record = environment();
      const owner = new AbortController();
      const service = createNodeWorkspaceTransferService({
        temporaryRoot: path.join(root, "transfers"),
        getOwner: () => ({
          environment: record,
          credential: { ownerEpoch: record.ownerEpoch, sessionId: "session-1" },
        }),
      });
      const entered = createDeferred();
      const release = createDeferred();
      const originalRealpath = fs.realpath.bind(fs);
      let blocked = false;
      const realpath = vi.spyOn(fs, "realpath").mockImplementation(async (...args) => {
        if (!blocked && args[0] === localPath) {
          blocked = true;
          entered.resolve();
          await release.promise;
        }
        return await originalRealpath(...args);
      });
      const request = {
        environmentId: record.environmentId,
        ownerEpoch: record.ownerEpoch,
        sessionId: "session-1",
        generation: record.ownerEpoch,
        localPath,
        signal: owner.signal,
        isAuthorized: () => true,
      };
      let current = true;
      const closed = new Error("initiating source closed");
      try {
        const first = service.prepareSync(request);
        await entered.promise;
        const replacement = {
          ...request,
          authorize: () => {
            if (!current) throw closed;
          },
          baseCommit: "a".repeat(40),
          baseManifestRef: `sha256:${"b".repeat(64)}`,
        };
        const pending = (
          source === "local"
            ? service.prepareSync(replacement)
            : service.prepareRepository(replacement)
        ).then(
          () => undefined,
          (error: unknown) => error,
        );
        current = false;
        release.resolve();
        const prepared = await first;
        expect.soft(await pending).toBe(closed);
        expect(owner.signal.aborted).toBe(false);
        expect(
          service.authorize({
            token: prepared.token,
            route: {
              kind: "manifest",
              direction: "download",
              environmentId: record.environmentId,
              manifestRef: prepared.snapshot.manifestRef,
            },
          }),
        ).toBeDefined();
        // A later operation still uses independent workspace custody.
        const upload = service.prepareUpload(record.environmentId, prepared.snapshot.manifestRef);
        await service.revoke(record.environmentId, upload);
      } finally {
        release.resolve();
        realpath.mockRestore();
        await service.closeAll();
      }
    },
  );
});
