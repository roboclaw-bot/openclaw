// The real Codex entry registers both RPCs; replace only the native stdio peer.
import "../src/test-utils/prepare-compiled-subprocesses.js";
import { createHash, randomUUID } from "node:crypto";
import { readFile, unlink } from "node:fs/promises";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { expect, it } from "vitest";
import codex from "../extensions/codex/index.js";
import { CODEX_APP_SERVER_VERSION } from "../extensions/codex/test-api.js";
import { captureRuntimeConfigAsyncReader } from "../src/config/config.js";
import type { OpenClawConfig } from "../src/config/types.openclaw.js";
import { startGatewayServerCore } from "../src/gateway/server-start.js";
import { createProductState } from "../src/gateway/server.chat-product.test-support.js";
import { connectGatewayClient, disconnectGatewayClient } from "../src/gateway/test-helpers.e2e.js";
import {
  acquireGatewayE2ePortBlock,
  startClaimedGateway,
} from "../src/gateway/test-helpers.listener.js";
import {
  resetTestPluginRegistry,
  setTestPluginRegistry,
} from "../src/gateway/test-helpers.plugin-registry.js";
import {
  loadOrCreateDeviceIdentity,
  publicKeyRawBase64UrlFromPem,
} from "../src/infra/device-identity.js";
import { approveDevicePairing } from "../src/infra/device-pairing-approval.js";
import { requestDevicePairing } from "../src/infra/device-pairing.js";
import { createPluginRecord } from "../src/plugins/loader-records.js";
import { createRuntimeTestRegistry } from "../src/plugins/registry-runtime.test-helpers.js";
import { createPluginRuntime } from "../src/plugins/runtime/index.js";

const readUsage = "codex.accountUsage";
const prepareMethod = "codex.prepareResetCredit";
const consume = "codex.consumeResetCredit";
const workspaceId = "workspace-fixture";
const profileId = "openai:wire-a";
const selection = { agentId: "main", profileId };
const alias = { agentId: "main", profileId: "openai:wire-alias" };
const credential = (member: string) => {
  const claim = {
    "https://api.openai.com/auth": {
      chatgpt_account_id: workspaceId,
      chatgpt_user_id: "account-level-user",
      chatgpt_account_user_id: member,
    },
    "https://api.openai.com/profile": { email: `${member}@example.test` },
  };
  return {
    type: "oauth",
    provider: "openai",
    accountId: workspaceId,
    access: `e30.${Buffer.from(JSON.stringify(claim)).toString("base64url")}.synthetic`,
    refresh: "synthetic-refresh",
    expires: Date.now() + 86_400_000,
    email: "old-profile-label@example.test",
  };
};

// Each native client has its own login. Persist only the synthetic upstream's
// ledger: a successfully applied credit disappears from its offers even if the
// child dies before writing the response. No network or real credentials.
const peer = String.raw`
import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
const [ledger, version] = process.argv.slice(2);
let login;
for await (const line of createInterface({ input: process.stdin })) {
  const { id, method, params } = JSON.parse(line);
  if (id === undefined) continue;
  let result, error;
  let drop = false;
  const state = JSON.parse(readFileSync(ledger, 'utf8'));
  switch (method) {
    case 'initialize': result = { userAgent: 'fixture/' + version }; break;
    case 'account/login/start': {
      if (existsSync(ledger + '.reject-login')) {
        unlinkSync(ledger + '.reject-login');
        state.requests.push({ method: 'refused-login' });
        error = { code: -32603, message: 'Synthetic login unavailable' }; break;
      }
      if (params.type !== 'chatgptAuthTokens') throw Error('Expected subscription login');
      const claims = JSON.parse(Buffer.from(params.accessToken.split('.')[1], 'base64url'));
      login = { workspace: params.chatgptAccountId, email: claims['https://api.openai.com/profile'].email };
      result = { type: 'chatgptAuthTokens' }; break;
    }
    case 'account/read': result = { account: { type: 'chatgpt', email: login.email, planType: 'team' }, requiresOpenaiAuth: true }; break;
    case 'account/rateLimits/read': {
      if (existsSync(ledger + '.refuse-after-read')) renameSync(ledger + '.refuse-after-read', ledger + '.reject-login');
      if (existsSync(ledger + '.outage')) {
        state.requests.push({ method: 'failed-read', email: login.email });
        error = { code: -32603, message: 'Synthetic quota outage' }; break;
      }
      state.requests.push({ method: 'read', email: login.email });
      const credits = ['A', 'B'].filter(id => !state.used.includes(id)).map(id => ({ id, resetType: 'codexRateLimits', status: 'available', grantedAt: 1, expiresAt: null, title: null, description: null }));
      result = { accountId: login.workspace, rateLimits: { limitId: 'codex', primary: { usedPercent: 100, windowDurationMins: 300, resetsAt: 1999999999 }, secondary: null }, rateLimitResetCredits: { availableCount: credits.length, credits } }; break;
    }
    case 'account/rateLimitResetCredit/consume': {
      const { creditId, idempotencyKey } = params;
      if (existsSync(ledger + '.overload')) {
        unlinkSync(ledger + '.overload'); state.requests.push({method: 'ingress-refused', email: login.email, params});
        error = {code: -32001, message: 'Server overloaded; retry later.'}; break;
      }
      state.requests.push({ method: 'consume', email: login.email, params });
      if (state.used.includes(creditId)) {
        result = { outcome: state.keys[creditId] === idempotencyKey ? 'alreadyRedeemed' : 'noCredit' };
      } else if (['A', 'B'].includes(creditId)) {
        state.used.push(creditId); state.keys[creditId] = idempotencyKey;
        result = { outcome: 'reset' }; drop = true;
      } else throw Error('Unknown credit');
      break;
    }
    default: throw Error('Unexpected fixture method ' + method);
  }
  writeFileSync(ledger, JSON.stringify(state));
  if (drop) process.exit(0);
  process.stdout.write(JSON.stringify({ id, result, error }) + '\n');
}
`;

type Operation = { creditId: string; idempotencyKey: string };
type Permission = { confirmationId: string; waitMs: number };
type Usage = {
  resetCredits: {
    availableCount?: number;
    offers?: { creditId: string; expiresAt: number | null }[];
    accountBinding: string;
    accountLabel: string;
    pending?: Operation;
    recentReceipts?: (Operation & { outcome: string })[];
  };
};

it(
  "admits the first confirmed reset from independent dialogs and retains its receipt while the next result is pending",
  { timeout: 120_000 },
  async () => {
    const state = await createProductState("codex-reset-wire");
    await using cleanup = new AsyncDisposableStack();
    cleanup.defer(() => state.cleanup());
    Object.assign(state.envVars, {
      OPENCLAW_TEST_MINIMAL_GATEWAY: "1",
      CODEX_HOME: state.path("codex-home"),
      OPENAI_API_KEY: undefined,
      CODEX_API_KEY: undefined,
    });
    state.applyEnv();
    const claim = await acquireGatewayE2ePortBlock();
    cleanup.defer(() => claim.release());
    const origin = `http://127.0.0.1:${claim.port}`;
    const script = await state.writeText("peer.mjs", peer);
    const ledger = await state.writeJson("peer.json", { requests: [], keys: {}, used: [] });
    const observation = async (): Promise<{
      used: string[];
      requests: { method: string; email: string; params?: Operation }[];
    }> => JSON.parse(await readFile(ledger, "utf8"));
    const writes = async () =>
      (await observation()).requests.filter((req) => req.method === "consume");
    const config: OpenClawConfig = {
      agents: {
        defaults: { workspace: state.workspaceDir, skipBootstrap: true },
        entries: { main: {} },
      },
      plugins: {
        slots: { memory: "none" },
        entries: {
          codex: {
            enabled: true,
            config: {
              appServer: {
                command: process.execPath,
                args: [script, ledger, CODEX_APP_SERVER_VERSION],
              },
            },
          },
        },
      },
      gateway: {
        bind: "loopback",
        auth: { mode: "token", token: "synthetic-wire-token" },
        controlUi: { allowedOrigins: [origin] },
      },
    };
    await state.writeConfig(config);
    const saveMember = (member: string) =>
      state.writeAuthProfiles({
        version: 1,
        profiles: { [profileId]: credential(member), [alias.profileId]: credential("member-a") },
      });
    await saveMember("member-a");
    await captureRuntimeConfigAsyncReader()();
    const registry = createRuntimeTestRegistry(createPluginRuntime());
    const rootDir = path.resolve("extensions/codex");
    codex.register(
      registry.createApi(
        createPluginRecord({
          id: "codex",
          source: path.join(rootDir, "index.ts"),
          rootDir,
          origin: "bundled",
          enabled: true,
          configSchema: true,
        }),
        { config },
      ),
    );
    setTestPluginRegistry(registry.registry);
    cleanup.defer(resetTestPluginRegistry);
    const gateway = await startClaimedGateway(claim, () =>
      startGatewayServerCore(claim.port, { controlUiEnabled: false }),
    );
    cleanup.defer(() => gateway.close({ reason: "reset credit proof finished" }));
    await gateway.startupSettled;
    const connect = async (name: string, adminUi = true) => {
      const clientName = adminUi ? "openclaw-control-ui" : "gateway-client";
      const mode = adminUi ? "webchat" : "backend";
      const scopes = ["operator.admin"];
      const device = loadOrCreateDeviceIdentity({ identityKey: `reset-wire-${name}` });
      const request = await requestDevicePairing({
        deviceId: device.deviceId,
        publicKey: publicKeyRawBase64UrlFromPem(device.publicKeyPem),
        clientId: clientName,
        clientMode: mode,
        platform: "web",
        role: "operator",
        scopes,
        ...(adminUi && { browserOrigin: origin }),
      });
      expect(
        (await approveDevicePairing(request.request.requestId, { callerScopes: scopes }))?.status,
      ).toBe("approved");
      let methods: string[] = [];
      const client = await connectGatewayClient({
        url: `ws://127.0.0.1:${claim.port}`,
        token: "synthetic-wire-token",
        deviceIdentity: device,
        clientName,
        mode,
        platform: "web",
        scopes,
        ...(adminUi && { origin }),
        onHelloOk: (hello) => {
          methods = hello.features.methods;
        },
      });
      cleanup.defer(() => disconnectGatewayClient(client));
      expect(methods).toEqual(expect.arrayContaining([readUsage, prepareMethod, consume]));
      return client;
    };
    const first = await connect("first");
    const read = async (client: typeof first, selected = selection) =>
      (await client.request<Usage>(readUsage, selected)).resetCredits;
    const initial = await read(first);
    expect(initial).toMatchObject({
      accountLabel: "member-a@example.test · member-a · workspace-fixture",
      offers: [
        { creditId: "A", expiresAt: null },
        { creditId: "B", expiresAt: null },
      ],
      availableCount: 2,
      accountBinding: createHash("sha256")
        .update(JSON.stringify(["codex-reset-credit", workspaceId, "member-a"]))
        .digest("hex"),
    });
    const target = { ...selection, accountBinding: initial.accountBinding };
    const prepare = async (
      client: typeof first,
      params: typeof target & Operation & { afterReset?: string },
    ) => {
      const permission = await client.request<Permission>(prepareMethod, params);
      expect(permission).toMatchObject({ confirmationId: expect.any(String), waitMs: 5_000 });
      return {
        params: {
          ...params,
          confirmationId: permission.confirmationId,
        },
        waitMs: permission.waitMs,
      };
    };
    const denied = (request: Promise<unknown>) =>
      expect(request).rejects.toMatchObject({
        gatewayCode: expect.stringMatching(/^(INVALID_REQUEST|FORBIDDEN)$/u),
      });
    const second = await connect("second");
    const third = await connect("third");
    const backend = await connect("backend", false);
    const a = { creditId: "A", idempotencyKey: randomUUID() };
    const b = { creditId: "B", idempotencyKey: randomUUID() };
    const unsent = { creditId: "B", idempotencyKey: randomUUID() };
    const refused = await prepare(third, { ...target, ...unsent });
    await delay(refused.waitMs);
    await state.writeText("peer.json.refuse-after-read", "fail native login after verifying offer");
    await expect(third.request(consume, refused.params)).resolves.toEqual({
      outcome: "notOffered",
    });
    const receiptUnsent = { ...unsent, outcome: "notOffered" };
    const recovered = await read(second, alias);
    expect(recovered).toMatchObject({
      availableCount: 2,
      offers: [{ creditId: "A" }, { creditId: "B" }],
      recentReceipts: [receiptUnsent],
    });
    expect(recovered.pending).toBeUndefined();
    expect((await observation()).requests.filter((r) => r.method === "refused-login")).toHaveLength(
      1,
    );
    expect(await writes()).toEqual([]);
    const deniedAtIngress = { creditId: "B", idempotencyKey: randomUUID() };
    const overload = await prepare(third, {
      ...target,
      ...deniedAtIngress,
      afterReset: unsent.idempotencyKey,
    });
    await delay(overload.waitMs);
    await state.writeText("peer.json.overload", "reject only the first physical attempt");
    await expect(third.request(consume, overload.params)).resolves.toEqual({
      outcome: "notOffered",
    });
    const refusalReceipts = [{ ...deniedAtIngress, outcome: "notOffered" }, receiptUnsent];
    expect(await read(second, alias)).toMatchObject({
      availableCount: 2,
      recentReceipts: refusalReceipts,
    });
    expect(
      (await observation()).requests
        .filter((r) => r.method === "ingress-refused")
        .map((r) => r.params),
    ).toEqual([deniedAtIngress]);
    expect(await writes()).toEqual([]);
    const initialA = { ...target, ...a, afterReset: deniedAtIngress.idempotencyKey };
    await denied(backend.request(prepareMethod, initialA));
    await denied(first.request(consume, initialA));
    // B opens first but is not submitted. Neither that dialog nor an independent
    // second A dialog can reserve the subscription or replace the confirmed key.
    const unusedB = await prepare(third, {
      ...target,
      ...b,
      afterReset: deniedAtIngress.idempotencyKey,
    });
    const otherA = await prepare(second, { ...initialA, ...alias, idempotencyKey: randomUUID() });
    const firstOffer = await prepare(first, initialA);
    await denied(first.request(consume, firstOffer.params));
    expect(await writes()).toEqual([]);
    await delay(firstOffer.waitMs);
    await denied(second.request(consume, firstOffer.params)); // wrong connection
    await denied(backend.request(consume, firstOffer.params));
    expect(await writes()).toEqual([]);
    // Only first's explicit consume debits the peer; the native reply is lost.
    await expect(first.request(consume, firstOffer.params)).rejects.toMatchObject({
      gatewayCode: "UNAVAILABLE",
    });
    await denied(second.request(consume, otherA.params));
    await denied(third.request(consume, unusedB.params));
    expect((await writes()).map((r) => r.params)).toEqual([a]);
    expect((await observation()).used).toEqual(["A"]);
    // A is absent from the native offer list. The alias finds the original intent
    // both before the quota outage and while the provider cannot return any offers.
    const identity = { accountBinding: initial.accountBinding, accountLabel: initial.accountLabel };
    expect(await read(second, alias)).toMatchObject({ ...identity, pending: a, availableCount: 1 });
    const outage = await state.writeText("peer.json.outage", "quota unavailable");
    const pending = await read(second, alias);
    expect(pending).toMatchObject({ ...identity, pending: a });
    expect(pending.offers ?? []).toEqual([]);
    expect(pending.availableCount).toBeUndefined();
    expect((await observation()).requests.at(-1)?.method).toBe("failed-read");
    await denied(first.request(consume, firstOffer.params));
    const retry = await prepare(second, { ...initialA, ...alias });
    const beforeReplay = (await observation()).requests.length;
    await denied(second.request(consume, retry.params));
    await delay(retry.waitMs);
    await expect(second.request(consume, retry.params)).resolves.toEqual({
      outcome: "alreadyRedeemed",
    });
    expect((await observation()).requests.slice(beforeReplay)).toEqual([
      { method: "consume", email: "member-a@example.test", params: a },
    ]);
    const receiptA = { ...a, outcome: "alreadyRedeemed" };
    expect(await read(second, alias)).toMatchObject({
      ...identity,
      recentReceipts: [receiptA, ...refusalReceipts],
    });
    await unlink(outage);
    expect(await read(second)).toMatchObject({
      offers: [{ creditId: "B", expiresAt: null }],
      recentReceipts: [receiptA, ...refusalReceipts],
    });
    await denied(first.request(prepareMethod, { ...target, ...b })); // missing predecessor
    const next = { ...target, ...b, afterReset: a.idempotencyKey };
    const stale = await prepare(first, next);
    const fresh = await prepare(second, { ...next, ...alias });
    await saveMember("member-b");
    expect((await read(first)).accountBinding).not.toBe(target.accountBinding);
    await delay(fresh.waitMs);
    await denied(first.request(consume, stale.params)); // mature consent, changed membership
    expect(await writes()).toHaveLength(2);
    await expect(second.request(consume, fresh.params)).rejects.toMatchObject({
      gatewayCode: "UNAVAILABLE",
    });
    expect(await read(third, alias)).toMatchObject({
      ...identity,
      availableCount: 0,
      pending: b,
      recentReceipts: [receiptA, ...refusalReceipts],
    });
    expect((await writes()).map((r) => r.params)).toEqual([a, a, b]);
    expect((await observation()).used).toEqual(["A", "B"]);
  },
);
