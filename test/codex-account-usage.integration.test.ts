import "../src/test-utils/prepare-compiled-subprocesses.js";
import { afterEach, expect, it, vi } from "vitest";
import { loadCodexAccountUsageTestFixture } from "../extensions/codex/test-api.js";
import type { OAuthCredential } from "../src/agents/auth-profiles/types.js";
import type { OpenClawConfig } from "../src/config/types.openclaw.js";
import type { GatewayRequestHandlerOptions } from "../src/gateway/server-methods/types.js";
import { connectUserModelAccountAsync } from "../src/state/user-model-account-operations.js";
import { connectUserModelAccount } from "../src/state/user-model-accounts.js";
import { ensureProfileForEmail } from "../src/state/user-profiles.js";
import { observeMainThreadSql } from "../src/test-utils/main-thread-sql-spies.test-support.js";
import { withOpenClawTestState } from "../src/test-utils/openclaw-test-state.js";

const { createCodexAccountUsageTestFixture } = await loadCodexAccountUsageTestFixture();

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
      const respond = vi.fn<GatewayRequestHandlerOptions["respond"]>();
      const params = { agentId: "main", profileId };
      const context: Partial<GatewayRequestHandlerOptions["context"]> = {
        getRuntimeConfig: () => config,
        getClientConnIds: () => new Set(["settings"]),
      };
      const sql = observeMainThreadSql();
      sql.calibrate();
      try {
        await handleCodexAccountUsage({
          req: { type: "req", id: "personal-usage", method: "codex.accountUsage", params },
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
