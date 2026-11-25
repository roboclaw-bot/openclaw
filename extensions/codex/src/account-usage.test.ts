import "openclaw/plugin-sdk/compiled-subprocess-testing";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-contracts";
import type { GatewayRequestHandlerOptions } from "openclaw/plugin-sdk/gateway-runtime";
import { createPluginStateKeyedStoreV2ForTests } from "openclaw/plugin-sdk/plugin-state-test-runtime";
import type { AuthProfileStore } from "openclaw/plugin-sdk/provider-auth";
import { withAuthProfileStoreAtEffect } from "openclaw/plugin-sdk/provider-auth-runtime";
import { createOpenClawTestState } from "openclaw/plugin-sdk/test-state";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { handleCodexAccountUsage, handleCodexResetCredit } from "./account-usage-runtime.js";
import { prepareCodexAppServerAuthBinding } from "./app-server/auth-binding.js";
import { CodexAppServerClient } from "./app-server/client.js";
import { resolveCodexAppServerRuntimeOptions } from "./app-server/config.js";
import { rememberCodexRateLimitsRead } from "./app-server/rate-limit-cache.js";
import {
  readCachedCodexAppServerUsage,
  readCodexAppServerUsage,
  requestCodexAppServerJson,
} from "./app-server/request.js";
import {
  getSharedCodexAppServerClient,
  retireSharedCodexAppServerClientIfCurrent,
} from "./app-server/shared-client.js";
import {
  createClientHarness,
  createCodexTestMemberAccess as access,
} from "./app-server/test-support.js";
import { CODEX_APP_SERVER_VERSION } from "./app-server/version.js";
import { ResetConfirmations } from "./reset-credit-confirmation.js";
import type { ResetRecord } from "./reset-credit.js";

vi.mock("openclaw/plugin-sdk/provider-auth-runtime", async (importOriginal) => ({
  ...(await importOriginal<typeof import("openclaw/plugin-sdk/provider-auth-runtime")>()),
  withAuthProfileStoreAtEffect: vi.fn(),
}));
vi.mock("./app-server/request.js", () => ({
  requestCodexAppServerJson: vi.fn(),
  readCodexAppServerUsage: vi.fn(),
  readCachedCodexAppServerUsage: vi.fn(),
}));

function usage(usedPercent: number) {
  return {
    rateLimits: {
      limitId: "codex",
      planType: "pro",
      primary: { usedPercent, windowDurationMins: 300, resetsAt: 1_800_000_000 },
    },
  };
}

const providerRequest = vi.mocked(requestCodexAppServerJson);

describe("Codex saved account usage and reset credits", () => {
  let confirmations: ResetConfirmations;
  let clock: number;
  let config: OpenClawConfig;
  let store: AuthProfileStore;
  let journalOffline: boolean;

  let state: Awaited<ReturnType<typeof createOpenClawTestState>>;
  beforeEach(async () => {
    state = await createOpenClawTestState({ label: "codex-credit" });
    vi.clearAllMocks();
    journalOffline = false;
    confirmations = new ResetConfirmations();
    clock = 1_000; // Integer origin keeps the mocked five-second floor exact.
    vi.spyOn(performance, "now").mockImplementation(() => clock);
    config = { agents: { entries: { main: {}, work: {} } } };
    store = {
      version: 1,
      profiles: {
        "openai:alex": {
          type: "oauth",
          provider: "openai",
          access: access(),
          refresh: "alex-refresh-placeholder",
          expires: 1_900_000_000_000,
          accountId: "alex-account",
          email: "same@example.test",
        },
        "openai:blair": {
          type: "token",
          provider: "openai",
          token: access("blair", "first", "blair-account"),
        },
        "openai:api": { type: "api_key", provider: "openai", key: "api-key-placeholder" },
      },
    };
    vi.mocked(withAuthProfileStoreAtEffect).mockImplementation(
      async (_agentDir, _options, consume) =>
        consume({ read: async () => store, assertCurrent() {} }),
    );
    providerRequest.mockReset().mockResolvedValue(usage(20));
    vi.mocked(readCodexAppServerUsage)
      .mockReset()
      .mockResolvedValue({ rateLimits: usage(20) });
    vi.mocked(readCachedCodexAppServerUsage).mockReset();
  });

  afterEach(async () => {
    vi.restoreAllMocks();
    await state.cleanup();
  });

  const admin: NonNullable<GatewayRequestHandlerOptions["client"]> = {
    connect: {
      minProtocol: 3,
      maxProtocol: 3,
      client: { id: "openclaw-control-ui", version: "test", platform: "web", mode: "webchat" },
      role: "operator",
      scopes: ["operator.admin"],
    },
    connId: "operator-ui",
    internal: { controlUiAdmin: true },
  };
  const methods = {
    read: "codex.accountUsage",
    prepare: "codex.prepareResetCredit",
    consume: "codex.consumeResetCredit",
  };
  function journal(assertCurrent: () => void) {
    if (journalOffline) {
      throw new Error("Fixture: receipt store offline");
    }
    return createPluginStateKeyedStoreV2ForTests<ResetRecord>(
      "codex",
      { namespace: "reset-credit-receipts", env: state.env, maxEntries: 100 },
      { assertCurrent },
    );
  }
  async function request(
    params: Record<string, unknown>,
    action: "read" | "prepare" | "consume" = "read",
    client: GatewayRequestHandlerOptions["client"] = admin,
    connected: GatewayRequestHandlerOptions["client"] = client,
  ) {
    const respond = vi.fn<GatewayRequestHandlerOptions["respond"]>();
    const context: Partial<GatewayRequestHandlerOptions["context"]> = {
      getRuntimeConfig: () => config,
      getClientConnIds: (filter) =>
        new Set(connected?.connId && (!filter || filter(connected)) ? [connected.connId] : []),
    };
    const options: GatewayRequestHandlerOptions = {
      req: { type: "req", id: "usage-request", method: methods[action], params },
      params,
      client,
      isWebchatConnect: () => false,
      respond,
      context: context as GatewayRequestHandlerOptions["context"],
      hasCurrentClientAuthority: () => true,
    };
    if (action === "read") {
      await handleCodexAccountUsage(options, journal);
    } else {
      await handleCodexResetCredit(options, journal, confirmations, action);
    }
    return respond;
  }

  it("reads the selected account in an isolated subscription session", async () => {
    vi.mocked(readCodexAppServerUsage).mockImplementation(async (options) => {
      expect(options.startOptions).toMatchObject({ homeScope: "agent", transport: "stdio" });
      expect(options.authRequirement).toBe("subscription");
      expect(options.authProfileId).toBeUndefined();
      const prepared = options.preparedAuth;
      if (prepared?.kind !== "profile") {
        throw new Error("Selected account was not prepared");
      }
      expect(prepared.store).not.toBe(store);
      options.assertCurrent?.();
      return { rateLimits: usage(prepared.profileId === "openai:alex" ? 11 : 72) };
    });
    for (const [profileId, usedPercent] of [
      ["openai:alex", 11],
      ["openai:blair", 72],
    ] as const) {
      const respond = await request({ agentId: "work", profileId }, "read", null);
      expect(respond).toHaveBeenCalledWith(
        true,
        expect.objectContaining({
          providers: [
            expect.objectContaining({
              provider: "openai",
              windows: [{ label: "5h", usedPercent, resetAt: 1_800_000_000_000 }],
            }),
          ],
        }),
      );
    }
  });

  it("returns an actionable read failure only for the requested profile and clears it on recovery", async () => {
    vi.mocked(readCachedCodexAppServerUsage).mockResolvedValue(undefined);
    const read = vi
      .mocked(readCodexAppServerUsage)
      .mockRejectedValueOnce(new Error("native transport detail"));
    const selected = { agentId: "work", profileId: "openai:blair" };
    const failed = await request(selected, "read", null);
    expect(failed.mock.calls[0]?.[2]).toMatchObject({
      code: "UNAVAILABLE",
      message: "Couldn't load this account's quota. Refresh to try again.",
    });
    for (const profileId of ["openai:alex", selected.profileId]) {
      const refreshed = await request({ ...selected, profileId }, "read", null);
      const answer = refreshed.mock.calls[0];
      expect(answer?.[0]).toBe(true);
      expect(answer?.[1]).toMatchObject({ providers: [{ windows: [{ usedPercent: 20 }] }] });
      expect(answer?.[1]).not.toHaveProperty("providers.0.error");
      expect(read.mock.lastCall?.[0].preparedAuth).toMatchObject({ profileId });
    }
  });

  it("distinguishes reserve quota from ordinary Luna in selected-account usage", async () => {
    const ordinary = usage(100).rateLimits;
    providerRequest.mockResolvedValue({
      rateLimits: ordinary,
      rateLimitsByLimitId: {
        codex: ordinary,
        base_model_inference: {
          limitId: "base_model_inference",
          limitName: "gpt-reserve",
          normalModelSlug: "gpt-5.6-luna",
          secondary: { usedPercent: 0, windowDurationMins: 10_080 },
        },
      },
      ordinaryUsageAllowed: null,
      rateLimitUpsell: null,
    });
    const respond = await request({ agentId: "work", profileId: "openai:alex" });
    expect(respond).toHaveBeenCalledWith(
      true,
      expect.objectContaining({
        providers: [
          expect.objectContaining({
            summary: expect.stringContaining("Ordinary Luna does not use this reserve"),
            windows: expect.arrayContaining([
              expect.objectContaining({
                groupLabel: "Luna Reserve (separate route)",
                usedPercent: 0,
              }),
            ]),
          }),
        ],
      }),
    );
  });

  it("rejects proxy launches before sending the selected account to a shared daemon", async () => {
    config.plugins = {
      entries: {
        codex: {
          config: { appServer: { args: ["app-server", "proxy", "--sock", "/tmp/codex.sock"] } },
        },
      },
    };
    const respond = await request({ agentId: "main", profileId: "openai:alex" });
    expect(respond).toHaveBeenCalledWith(
      false,
      undefined,
      expect.objectContaining({ code: "UNAVAILABLE", message: expect.stringContaining("proxy") }),
    );
    expect(providerRequest).not.toHaveBeenCalled();
  });

  it.each([
    { agentId: "../main", profileId: "openai:alex" },
    { profileId: "openai:alex" },
    { agentId: "main", profileId: "openai:api" },
  ])("rejects an unavailable or invalid selection without fetching: %j", async (params) => {
    const respond = await request(params);
    expect(respond).toHaveBeenCalledWith(
      false,
      undefined,
      expect.objectContaining({ code: expect.any(String) }),
    );
    expect(providerRequest).not.toHaveBeenCalled();
  });

  const selection = { agentId: "work", profileId: "openai:alex" };
  const spend = {
    ...selection,
    accountBinding: "0".repeat(64),
    creditId: "earned-one",
    idempotencyKey: "6daa828a-066a-4a8f-a71b-e5ae541bcead",
    confirmationId: "2dab34c6-3d58-4671-ab3a-a6db97c2a649",
  };

  it("keeps the newer dialog when a canceled preview finishes late", () => {
    const canceled = confirmations.begin(admin, spend);
    const current = confirmations.begin(admin, spend)("current");
    expect(() => canceled("old")).toThrow("replaced");
    clock += 4_999;
    expect(confirmations.take(admin, { ...spend, ...current })).toBeUndefined();
    clock++;
    expect(confirmations.take(admin, { ...spend, ...current })).toEqual({ comparison: "current" });
  });

  async function afterWait(target: typeof spend) {
    const { confirmationId: _unused, ...args } = target;
    const [ok, ticket] = (await request(args, "prepare")).mock.calls[0]!;
    expect(ok).toBe(true);
    clock += 5_000;
    return { ...args, confirmationId: (ticket as { confirmationId: string }).confirmationId };
  }

  const offer = (id: string) => ({
    id,
    resetType: "codexRateLimits",
    status: "available",
    expiresAt: null,
  });
  const row = offer(spend.creditId);

  async function balance(profileId = selection.profileId) {
    const [ok, payload] = (await request({ ...selection, profileId })).mock.calls[0]!;
    expect(ok).toBe(true);
    type Balance = Pick<typeof spend, "accountBinding"> & {
      creditId?: string;
      lastReset?: ResetRecord;
    };
    return (payload as { resetCredits: Balance }).resetCredits;
  }
  const limits = (...ids: string[]) => ({
    ...usage(80),
    rateLimitResetCredits: {
      availableCount: ids.length,
      credits: ids.map(offer),
    },
  });
  async function offeredIntent() {
    providerRequest.mockResolvedValue(limits(row.id));
    return afterWait({ ...spend, accountBinding: (await balance()).accountBinding });
  }

  it("offers eligible credits soonest-expiring first; count alone cannot select one", async () => {
    const expiresAt = Math.floor(Date.now() / 1000) + 3600;
    const credits = [
      { ...row, id: "expired", expiresAt: 1 },
      { ...row, id: "unknown", resetType: "unknown" },
      { ...row, id: "used", status: "redeemed" },
      row,
      { ...row, id: "expiring", expiresAt, title: "Gift" },
    ];
    providerRequest.mockResolvedValue({
      rateLimitResetCredits: { availableCount: 2, credits },
    });
    expect(await balance()).toMatchObject({
      availableCount: 2,
      creditId: "expiring",
      offers: [
        { creditId: "expiring", expiresAt, title: "Gift" },
        { creditId: row.id, expiresAt: null },
      ],
    });
    providerRequest.mockResolvedValue({
      rateLimitResetCredits: { availableCount: 2, credits: null },
    });
    expect((await balance()).creditId).toBeUndefined();
    expect(providerRequest.mock.calls.map(([call]) => call.method)).toEqual(
      Array(2).fill("account/rateLimits/read"),
    );
  });

  it("reads pre-history receipts while journal outages preserve identity but never offer spending", async () => {
    providerRequest.mockResolvedValue(limits(row.id));
    const { accountBinding } = await balance();
    const legacy = {
      creditId: row.id,
      idempotencyKey: spend.idempotencyKey,
      outcome: "reset" as const,
    };
    await journal(() => {}).register(accountBinding, legacy);
    providerRequest.mockResolvedValueOnce({
      ...limits("another-credit"),
      accountId: "other-workspace",
    });
    const foreign = await balance();
    expect(foreign).toMatchObject({ accountBinding, lastReset: legacy, recentReceipts: [legacy] });
    expect(foreign).not.toHaveProperty("offers");
    journalOffline = true;
    const offline = await balance();
    expect(offline).toMatchObject({
      accountBinding,
      memberId: "alex",
      availableCount: 1,
      journalUnavailable: true,
    });
    expect(offline.creditId).toBeUndefined();
    expect(providerRequest.mock.calls.every(([p]) => p.method === "account/rateLimits/read")).toBe(
      true,
    );
  });

  it("rejects implicit, unattended, private-account and unconfirmed spending before provider access", async () => {
    const synthetic = {
      ...admin,
      internal: { controlUiAdmin: true, syntheticClient: true },
    } as const;
    const privateAccount = {
      ...spend,
      profileId:
        "personal:18b3c35a-9f38-4aad-acae-e34581d76649:5a578283-e82a-41bb-82be-9f0907dd7787",
    };
    for (const [params, client, connected, code] of [
      [spend, null, null, "FORBIDDEN"],
      [spend, synthetic, synthetic, "FORBIDDEN"],
      [spend, { ...admin }, admin, "FORBIDDEN"],
      [privateAccount, admin, admin, "FORBIDDEN"],
      [{ ...spend, confirmationId: "" }, admin, admin, "INVALID_REQUEST"],
      [{ ...spend, creditId: undefined }, admin, admin, "INVALID_REQUEST"],
      [{ ...spend, accountBinding: undefined }, admin, admin, "INVALID_REQUEST"],
    ] as const) {
      const response = await request(params, "consume", client, connected);
      expect(response.mock.calls[0]?.[2]?.code).toBe(code);
    }
    expect((await request(spend, "read")).mock.calls[0]?.[2]?.code).toBe("INVALID_REQUEST");
    expect(providerRequest).not.toHaveBeenCalled();
  });

  // The signed WebSocket test owns wrong-member refusal, lost receipt, alias recovery and A/A/B effects.
  it("rejects a mismatched workspace or missing membership but tolerates same-member token rotation", async () => {
    const original = store.profiles[selection.profileId];
    if (original?.type !== "oauth") {
      throw new Error("expected OAuth fixture");
    }
    for (const change of [
      { accountId: "mismatch" },
      { access: access(null) },
      { access: access("another-member") },
      // Same email and member claim, different valid workspace login.
      { accountId: "another-workspace", access: access("alex", "first", "another-workspace") },
    ]) {
      const target = await offeredIntent();
      store.profiles[selection.profileId] = { ...original, ...change };
      providerRequest.mockClear();
      expect((await request(target, "consume")).mock.calls[0]?.[2]?.code).toBe("INVALID_REQUEST");
      expect(providerRequest).not.toHaveBeenCalled();
      store.profiles[selection.profileId] = original;
    }
    store.profiles["openai:alias"] = { ...original, access: access("alex", "rotated") };
    store.profiles["openai:other-workspace"] = {
      ...original,
      accountId: "another-workspace",
      access: access("alex", "first", "another-workspace"),
    };
    const target = await offeredIntent();
    expect((await balance("openai:alias")).accountBinding).toBe(target.accountBinding);
    expect((await balance("openai:other-workspace")).accountBinding).not.toBe(
      target.accountBinding,
    );
    store.profiles[selection.profileId] = store.profiles["openai:alias"];
    providerRequest
      .mockResolvedValueOnce(limits("other", row.id))
      .mockResolvedValueOnce({ outcome: "reset" });
    expect(await request(target, "consume")).toHaveBeenCalledWith(true, { outcome: "reset" });
  });

  it("keeps the original pending when an exact retry fails before a native write", async () => {
    const target = await offeredIntent();
    providerRequest
      .mockResolvedValueOnce(limits(row.id))
      .mockImplementationOnce(async (options) => {
        options.onRequestWrite?.();
        throw new Error("Reply lost after the first native write");
      });
    const failReaderCleanup = () =>
      vi
        .mocked(withAuthProfileStoreAtEffect)
        .mockImplementationOnce(async (_dir, _options, consume) => {
          const cleanup = new Error("Reader disposal failed");
          try {
            await consume({ read: async () => store, assertCurrent() {} });
          } catch (cause) {
            throw new AggregateError([cause, cleanup], "Read and disposal failed", { cause });
          }
          throw cleanup;
        });
    failReaderCleanup();
    expect((await request(target, "consume")).mock.calls[0]?.[2]?.code).toBe("UNAVAILABLE");
    const retry = await afterWait(target);
    providerRequest.mockRejectedValueOnce(new Error("Native login unavailable before the retry"));
    expect((await request(retry, "consume")).mock.calls[0]?.[2]?.code).toBe("UNAVAILABLE");
    expect(await balance()).toMatchObject({
      pending: { creditId: target.creditId, idempotencyKey: target.idempotencyKey },
    });
    expect((await balance()).lastReset).toBeUndefined();
    const overloaded = await afterWait(target);
    providerRequest.mockImplementationOnce(async (options) => {
      options.onRequestWrite?.();
      options.onIngressRejected?.();
      throw new Error("Declined before enqueue");
    });
    expect((await request(overloaded, "consume")).mock.calls[0]?.[2]?.code).toBe("UNAVAILABLE");
    const recovery = await afterWait(target);
    providerRequest.mockResolvedValueOnce({ outcome: "alreadyRedeemed" });
    failReaderCleanup();
    expect(await request(recovery, "consume")).toHaveBeenCalledExactlyOnceWith(true, {
      outcome: "alreadyRedeemed",
    });
  });

  it("records a no-send receipt for an unadmitted, no-longer-offered id and fences a delayed duplicate", async () => {
    const target = await offeredIntent();
    providerRequest.mockResolvedValue(limits("other"));
    const recovered = await afterWait(target);
    expect(await request(recovered, "consume")).toHaveBeenCalledWith(true, {
      outcome: "notOffered",
    });
    providerRequest.mockClear().mockResolvedValue(limits(row.id));
    expect(await request(await afterWait(target), "consume")).toHaveBeenCalledWith(true, {
      outcome: "notOffered",
    });
    expect(providerRequest).not.toHaveBeenCalled();
    expect((await balance()).lastReset).toEqual({
      creditId: row.id,
      idempotencyKey: target.idempotencyKey,
      outcome: "notOffered",
    });
  });

  it("does not retire a confirmed ID when Codex supplies only a positive count", async () => {
    const target = await offeredIntent();
    providerRequest.mockResolvedValueOnce({
      rateLimitResetCredits: { availableCount: 1, credits: null },
    });
    expect(await request(target, "consume")).toHaveBeenCalledWith(
      false,
      undefined,
      expect.anything(),
    );
    providerRequest.mockResolvedValue(limits(row.id));
    expect((await balance()).lastReset).toBeUndefined();
  });

  it("uses the warm quota only for its saved member when the fresh native read fails", async () => {
    const { withAuthProfileStoreAtEffect: persistedReader } = await vi.importActual<
      typeof import("openclaw/plugin-sdk/provider-auth-runtime")
    >("openclaw/plugin-sdk/provider-auth-runtime");
    vi.mocked(withAuthProfileStoreAtEffect).mockImplementation(persistedReader);
    const native =
      await vi.importActual<typeof import("./app-server/request.js")>("./app-server/request.js");
    vi.mocked(readCachedCodexAppServerUsage).mockImplementation(
      native.readCachedCodexAppServerUsage,
    );
    vi.mocked(readCodexAppServerUsage).mockImplementation(native.readCodexAppServerUsage);
    providerRequest.mockImplementation(native.requestCodexAppServerJson);
    const appServer = { command: state.path("synthetic-codex"), homeScope: "agent" as const };
    config.plugins = { entries: { codex: { config: { appServer } } } };
    await state.writeConfig(config);
    const agentDir = state.agentDir(selection.agentId);
    const profileId = selection.profileId;
    await state.writeAuthProfiles(
      { ...store, profiles: { ...store.profiles, "openai:alias": store.profiles[profileId]! } },
      selection.agentId,
    );
    const failedReads: string[] = [];
    const wrongWorkspace = {
      ...limits("foreign-credit"),
      accountId: "other-workspace",
      rateLimits: { ...usage(94).rateLimits, credits: { balance: "37" } },
    };
    const peer = (offline = false, reply = usage(80)) => {
      let selected = "";
      return createClientHarness({
        onWrite: (line, send) => {
          const { id, method, params } = JSON.parse(line) as {
            id?: number;
            method: string;
            params?: { accessToken: string };
          };
          if (id === undefined) {
            return;
          }
          if (method === "account/login/start") {
            selected = params?.accessToken ?? "";
          }
          if (method === "account/rateLimits/read" && offline) {
            failedReads.push(selected);
            send({ id, error: { code: -32603, message: "synthetic quota outage" } });
            return;
          }
          const responses: Record<string, unknown> = {
            initialize: { userAgent: "fixture/" + CODEX_APP_SERVER_VERSION },
            "account/login/start": { type: "chatgptAuthTokens" },
            "account/rateLimits/read": reply,
            "account/read": { account: null },
          };
          if (Object.hasOwn(responses, method)) {
            send({ id, result: responses[method] });
          }
        },
      });
    };
    const wire = peer();
    const start = vi
      .spyOn(CodexAppServerClient, "start")
      .mockResolvedValueOnce(wire.client)
      .mockImplementation(async () => peer(true).client);
    try {
      const binding = await prepareCodexAppServerAuthBinding({
        authProfileId: profileId,
        authProfileStore: store,
        agentDir,
        config,
      });
      const startOptions = resolveCodexAppServerRuntimeOptions({
        pluginConfig: { appServer },
      }).start;
      const live = await getSharedCodexAppServerClient({
        agentDir,
        config,
        startOptions,
        preparedAuth: { kind: "profile", profileId, store },
        authRequirement: "subscription",
        authBindingFingerprint: binding?.fingerprint,
      });
      rememberCodexRateLimitsRead(live, { ...limits(row.id), accountId: "alex-account" });
      const observedAt = Date.now();
      const now = vi.spyOn(Date, "now").mockReturnValue(observedAt);
      const observed = new Promise<void>((done) => {
        live.addNotificationHandler(() => done());
      });
      wire.send({ method: "account/rateLimits/updated", params: usage(27) });
      await observed;
      const options = {
        agentDir,
        authProfileId: profileId,
        startOptions,
        config,
        timeoutMs: 3_000,
      };
      const ttl = (cacheTtlMs: number) => ({ ...config, models: { usage: { cacheTtlMs } } });
      now.mockReturnValue(observedAt + 90_000);
      expect(
        await native.readCachedCodexAppServerUsage({ ...options, config: ttl(120_000) }),
      ).toMatchObject({ rateLimits: usage(27) });
      now.mockReturnValue(observedAt + 60_000);
      // Exactly at the default TTL, general usage falls back to an isolated native read.
      start.mockResolvedValueOnce(peer().client);
      expect(await native.readCodexAppServerUsage(options)).toMatchObject({
        rateLimits: usage(80),
      });
      now.mockReturnValue(observedAt);
      for (const other of [
        { config: ttl(0) },
        { agentDir: state.agentDir("main") },
        { authProfileId: "openai:alias" },
        { startOptions: { ...startOptions, args: ["app-server", "-c", "different=true"] } },
      ]) {
        expect(
          await native.readCachedCodexAppServerUsage({ ...options, ...other }),
        ).toBeUndefined();
      }
      expect(start).toHaveBeenCalledTimes(2);
      expect(wire.writes.map((line) => JSON.parse(line).method)).not.toContain(
        "account/rateLimits/read",
      );
      const load = async (quotaOnly = false) =>
        (await request({ ...selection, ...(quotaOnly && { quotaOnly }) })).mock.calls[0]?.[1];
      const warm = { stale: true, providers: [{ windows: [{ usedPercent: 27 }] }] };
      expect(await load(true)).toMatchObject(warm);
      const same = await load();
      expect(same).toMatchObject({ ...warm, resetCredits: { memberId: "alex" } });
      expect(same).not.toHaveProperty("resetCredits.creditId");
      const saved = store.profiles[profileId];
      if (saved?.type !== "oauth") {
        throw new Error("Expected fixture OAuth login");
      }
      const replaceAccess = (member: string | null, workspace = saved.accountId) =>
        state.writeAuthProfiles(
          {
            ...store,
            profiles: {
              [profileId]: {
                ...saved,
                accountId: workspace,
                access: access(member, "rotated", workspace),
              },
            },
          },
          selection.agentId,
        );
      await replaceAccess("alex");
      expect(await load(true)).toMatchObject(warm);
      await replaceAccess("blair");
      const rebound = await load();
      expect(rebound).toMatchObject({
        providers: [{ windows: [] }],
        resetCredits: { memberId: "blair" },
      });
      expect(rebound).not.toHaveProperty("stale");
      expect(failedReads).toEqual([access(), access("blair", "rotated")]);
      expect(await load(true)).toMatchObject({ providers: [] });
      await replaceAccess(null);
      expect(await load(true)).toMatchObject({ providers: [] });
      await replaceAccess("alex", "other-workspace");
      expect(await load(true)).toMatchObject({ providers: [] });
      await replaceAccess("alex");
      expect(await load(true)).toMatchObject(warm);
      const unavailable = expect.objectContaining({
        providers: [
          {
            provider: "openai",
            displayName: "OpenAI",
            windows: [],
            error: "Couldn't load this account's quota. Refresh to try again.",
          },
        ],
        resetCredits: expect.objectContaining({ memberId: "alex", workspaceId: "alex-account" }),
      });
      const foreignPeer = peer(false, wrongWorkspace);
      start.mockResolvedValueOnce(foreignPeer.client);
      const foreign = await load();
      expect(
        foreignPeer.writes
          .map((line) => JSON.parse(line))
          .find((rpc) => rpc.method === "account/login/start")?.params.chatgptAccountId,
      ).toBe("alex-account");
      expect(foreign).not.toHaveProperty("resetCredits.availableCount");
      expect(foreign).not.toHaveProperty("resetCredits.offers");
      start.mockResolvedValueOnce(peer(false, wrongWorkspace).client);
      const readOnly = (await request(selection, "read", null)).mock.calls[0]?.[1];
      expect(readOnly).toMatchObject({ providers: [{ windows: [], error: expect.any(String) }] });
      expect(readOnly).not.toHaveProperty("resetCredits");
      rememberCodexRateLimitsRead(live, wrongWorkspace);
      expect([foreign, await load(true), await load()]).toEqual([
        unavailable,
        expect.objectContaining({ providers: [] }),
        unavailable,
      ]);
      rememberCodexRateLimitsRead(live, usage(27));
      expect(await load(true)).toMatchObject(warm);
      retireSharedCodexAppServerClientIfCurrent(live);
      expect(await load(true)).toMatchObject({ providers: [] });
    } finally {
      await wire.client.closeAndWait();
    }
  });
});
