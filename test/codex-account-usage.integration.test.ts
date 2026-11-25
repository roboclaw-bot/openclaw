import "../src/test-utils/prepare-compiled-subprocesses.js";
import { afterEach, expect, it, vi } from "vitest";
import { loadCodexAccountUsageTestFixture } from "../extensions/codex/test-api.js";
import { ensureAuthProfileStoreAsync } from "../src/agents/auth-profiles.js";
import type { OAuthCredential } from "../src/agents/auth-profiles/types.js";
import { readCodexCliCredentialsCached } from "../src/agents/cli-credentials.js";
import type { OpenClawConfig } from "../src/config/types.openclaw.js";
import type { GatewayRequestHandlerOptions } from "../src/gateway/server-methods/types.js";
import { connectUserModelAccountAsync } from "../src/state/user-model-account-operations.js";
import { connectUserModelAccount } from "../src/state/user-model-accounts.js";
import { ensureProfileForEmail } from "../src/state/user-profiles.js";
import { observeMainThreadSql } from "../src/test-utils/main-thread-sql-spies.test-support.js";
import { withOpenClawTestState } from "../src/test-utils/openclaw-test-state.js";

const { createCodexAccountUsageTestFixture } = await loadCodexAccountUsageTestFixture();

async function settingsUsage(
  handle: ReturnType<typeof createCodexAccountUsageTestFixture>["handleCodexAccountUsage"],
  config: OpenClawConfig,
  profileId: string,
  quotaOnly = false,
) {
  const params = { agentId: "main", profileId, ...(quotaOnly && { quotaOnly: true }) };
  const respond = vi.fn<GatewayRequestHandlerOptions["respond"]>();
  const context: Partial<GatewayRequestHandlerOptions["context"]> = {
    getRuntimeConfig: () => config,
    getClientConnIds: () => new Set(["settings"]),
  };
  await handle({
    req: { type: "req", id: "account-usage", method: "codex.accountUsage", params },
    params,
    client: {
      connId: "settings",
      internal: { controlUiAdmin: true },
      connect: {
        minProtocol: 3,
        maxProtocol: 3,
        client: {
          id: "openclaw-control-ui",
          version: "test",
          platform: "web",
          mode: "webchat",
        },
        role: "operator",
        scopes: ["operator.admin"],
      },
    },
    isWebchatConnect: () => false,
    respond,
    context: context as GatewayRequestHandlerOptions["context"],
    hasCurrentClientAuthority: () => true,
  });
  return respond;
}

it("rejects non-native ChatGPT grants before preparing subscription or cached quota", async () => {
  await withOpenClawTestState({ scenario: "minimal" }, async (state) => {
    const { handleCodexAccountUsage, readCodexAppServerUsage } =
      createCodexAccountUsageTestFixture();
    // No native process is expected. Even on regression the fixture cannot reach a real provider.
    const config: OpenClawConfig = {
      agents: { entries: { main: { agentDir: state.agentDir() } } },
      plugins: {
        entries: { codex: { config: { appServer: { command: state.path("no-peer") } } } },
      },
    };
    Object.assign(state.envVars, {
      CODEX_HOME: state.statePath("host-codex"),
      OPENAI_API_KEY: undefined,
      CODEX_API_KEY: undefined,
    });
    state.applyEnv();
    const idToken = `e30.${Buffer.from(JSON.stringify({ sub: "synthetic-subject" })).toString("base64url")}.fixture`;
    const credential = {
      type: "oauth",
      provider: "openai",
      access: "fixture-access",
      refresh: "fixture-refresh",
      expires: Date.now() + 86_400_000,
      idToken,
      issuer: "https://issuer.example.test",
      clientId: "fixture-client",
    };
    // A separate host CLI login is readable in the fixture but is not a saved agent slot.
    await state.writeJson("host-codex/auth.json", {
      auth_mode: "chatgpt",
      tokens: {
        access_token: "host-fixture-access",
        refresh_token: "host-fixture-refresh",
        account_id: "host-fixture",
      },
    });
    expect(readCodexCliCredentialsCached({ allowKeychainPrompt: false })).toMatchObject({
      accountId: "host-fixture",
    });
    await state.writeConfig(config);
    await state.writeAuthProfiles({
      version: 1,
      profiles: {
        "openai:sharing": { ...credential, authFlow: "chatgpt-token-sharing" },
        "openai:identity": { ...credential, authFlow: "chatgpt-identity" },
      },
    });
    const inventory = await ensureAuthProfileStoreAsync(state.agentDir(), {
      config,
      externalCliProviderIds: ["openai"],
      allowKeychainPrompt: false,
    });
    expect(Object.keys(inventory.profiles).toSorted()).toEqual([
      "openai:identity",
      "openai:sharing",
    ]);
    for (const profileId of ["openai:sharing", "openai:identity"]) {
      for (const cache of [false, true]) {
        const respond = await settingsUsage(handleCodexAccountUsage, config, profileId, cache);
        expect(respond.mock.calls[0]?.[2]).toMatchObject({
          code: "INVALID_REQUEST",
          message: "This login does not provide Codex quota.",
        });
      }
    }
    expect(readCodexAppServerUsage).not.toHaveBeenCalled();
  });
});

afterEach(() => vi.restoreAllMocks());

it.each([false, true])(
  "uses personal account authority without main-thread SQL (reconnect: %s)",
  async (reconnect) =>
    withOpenClawTestState({ scenario: "minimal" }, async () => {
      const { handleCodexAccountUsage, readCodexAppServerUsage } =
        createCodexAccountUsageTestFixture();
      const config: OpenClawConfig = {
        agents: { entries: { main: {} } },
        plugins: { enabled: false },
      };
      const credential: OAuthCredential = {
        type: "oauth",
        provider: "openai",
        access: "synthetic-account-access",
        refresh: "synthetic-account-refresh",
        expires: 1_900_000_000_000,
        accountId: "synthetic-account",
      };
      const connection = {
        ownerProfileId: ensureProfileForEmail("account-usage@example.test").id,
        credential,
        assertCurrent() {},
      };
      const { authProfileId: profileId } = connectUserModelAccount(connection);
      const reconnected: {
        account: Awaited<ReturnType<typeof connectUserModelAccountAsync>> | null;
      } = { account: null };
      readCodexAppServerUsage.mockImplementation(async (options) => {
        options.assertCurrent?.();
        if (reconnect) {
          reconnected.account = await connectUserModelAccountAsync({
            ...connection,
            matchesCredential: () => true,
          });
        }
        return {
          rateLimits: {
            rateLimits: { limitId: "codex" },
            rateLimitResetCredits: {
              availableCount: 1,
              credits: [
                {
                  id: "private-credit",
                  status: "available",
                  resetType: "codexRateLimits",
                  expiresAt: null,
                },
              ],
            },
          },
        };
      });
      const sql = observeMainThreadSql();
      sql.calibrate();
      try {
        const respond = await settingsUsage(handleCodexAccountUsage, config, profileId);
        expect(readCodexAppServerUsage.mock.calls[0]?.[0].preparedAuth).toMatchObject({
          kind: "profile",
          profileId,
          store: { profiles: { [profileId]: credential } },
        });
        if (reconnect) {
          expect(reconnected.account?.authProfileId).toBe(profileId);
        }
        const provider = expect.objectContaining({ provider: "openai" });
        const expected = reconnect
          ? [false, undefined, expect.objectContaining({ code: "UNAVAILABLE" })]
          : [
              true,
              expect.objectContaining({
                providers: [provider],
                resetCredits: { availableCount: 1, readOnly: true },
              }),
            ];
        expect(respond).toHaveBeenCalledWith(...expected);
        sql.expectIdle();
      } finally {
        sql.restore();
      }
    }),
);
