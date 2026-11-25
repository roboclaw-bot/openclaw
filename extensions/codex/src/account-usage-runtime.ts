import { isDeepStrictEqual } from "node:util";
import { listAgentIds, resolveAgentDir } from "openclaw/plugin-sdk/agent-scope-runtime";
import { ErrorCodes, errorShape } from "openclaw/plugin-sdk/gateway-runtime";
import type { GatewayRequestHandlerOptions } from "openclaw/plugin-sdk/gateway-runtime";
import type { AuthProfileStore } from "openclaw/plugin-sdk/provider-auth";
import {
  isUserModelAuthProfileId,
  withAuthProfileStoreAtEffect,
  withPersonalAuthProfileStore,
} from "openclaw/plugin-sdk/provider-auth-runtime";
import { z } from "zod";
import { resolveCodexAppServerPreparedAuthProfileSnapshot } from "./app-server/auth-bridge.js";
import { supportsCodexSubscriptionAuth } from "./app-server/auth-profile.js";
import { readCodexPluginConfig, resolveCodexAppServerRuntimeOptions } from "./app-server/config.js";
import { isCodexAppServerProxyLaunch } from "./app-server/launch-args.js";
import { codexRateLimitsMatchWorkspace } from "./app-server/rate-limit-cache.js";
import { buildCodexAppServerUsageSnapshot } from "./app-server/rate-limits.js";
import {
  readCachedCodexAppServerUsage,
  readCodexAppServerUsage,
  requestCodexAppServerJson,
} from "./app-server/request.js";
import { codexSubscriptionMember } from "./app-server/subscription-member.js";
import type { ResetConfirmations } from "./reset-credit-confirmation.js";
import {
  creditId,
  isResetCreditOffered,
  readResetCreditBalance,
  observeResetRecord,
  spendResetCredit,
  type ResetStore,
} from "./reset-credit.js";

const quotaUnavailable = "Couldn't load this account's quota. Refresh to try again.";

type OpenResetStore = (assertCurrent: () => void) => ResetStore;
const accountParams = z.strictObject({ agentId: z.string().min(1), profileId: z.string().min(1) });
const readParams = accountParams.extend({ quotaOnly: z.literal(true).optional() });
const prepareParams = accountParams.extend({
  creditId,
  accountBinding: z.string().regex(/^[0-9a-f]{64}$/u),
  idempotencyKey: z.uuid(),
  afterReset: z.uuid().optional(),
});
const spendParams = prepareParams.extend({ confirmationId: z.uuid() });
function canSpendFromSettings(
  { client, context }: GatewayRequestHandlerOptions,
  profileId: string,
) {
  // Models manages agent credentials. An administrator's access to that page does
  // not authorize spending a user's privately owned subscription credit.
  return (
    !isUserModelAuthProfileId(profileId) &&
    client?.internal?.controlUiAdmin === true &&
    !client.internal.syntheticClient &&
    !client.internal.agentRuntimeIdentity &&
    !client.internal.agentToolCaller &&
    typeof client.connId === "string" &&
    client.connId.length > 0 &&
    context.getClientConnIds?.((connected) => connected === client).has(client.connId) === true
  );
}

export async function handleCodexAccountUsage(
  options: GatewayRequestHandlerOptions,
  openStore?: OpenResetStore,
): Promise<void> {
  const parsed = readParams.safeParse(options.params);
  if (!parsed.success) {
    options.respond(
      false,
      undefined,
      errorShape(ErrorCodes.INVALID_REQUEST, "Expected agentId and profileId."),
    );
    return;
  }
  await handleSavedAccount(options, { kind: "read", selection: parsed.data, openStore });
}

export async function handleCodexResetCredit(
  options: GatewayRequestHandlerOptions,
  openStore: OpenResetStore,
  confirmations: ResetConfirmations,
  action: "prepare" | "consume" = "consume",
): Promise<void> {
  const parsed = (action === "prepare" ? prepareParams : spendParams).safeParse(options.params);
  if (!parsed.success) {
    options.respond(
      false,
      undefined,
      errorShape(
        ErrorCodes.INVALID_REQUEST,
        "Confirm the exact account and reset credit in Models settings.",
      ),
    );
    return;
  }
  if (!options.client || !canSpendFromSettings(options, parsed.data.profileId)) {
    options.respond(
      false,
      undefined,
      errorShape(
        ErrorCodes.FORBIDDEN,
        "Use an authenticated administrator's Models settings for an agent's saved subscription.",
      ),
    );
    return;
  }
  if (action === "prepare") {
    await handleSavedAccount(options, {
      kind: "prepare",
      selection: parsed.data,
      openStore,
      finish: confirmations.begin(options.client, parsed.data),
    });
    return;
  }
  if (!("confirmationId" in parsed.data) || typeof parsed.data.confirmationId !== "string") {
    throw new Error("Invalid confirmation");
  }
  const permit = confirmations.take(options.client, {
    ...parsed.data,
    confirmationId: parsed.data.confirmationId,
  });
  if (!permit) {
    options.respond(
      false,
      undefined,
      errorShape(
        ErrorCodes.INVALID_REQUEST,
        "Reset not sent. Reopen the confirmation and wait five seconds.",
      ),
    );
    return;
  }
  await handleSavedAccount(options, {
    kind: "consume",
    selection: parsed.data,
    openStore,
    comparison: permit.comparison,
  });
}

type Operation =
  | { kind: "read"; selection: z.infer<typeof readParams>; openStore?: OpenResetStore }
  | {
      kind: "prepare";
      selection: z.infer<typeof prepareParams>;
      openStore: OpenResetStore;
      finish: ReturnType<ResetConfirmations["begin"]>;
    }
  | {
      kind: "consume";
      selection: z.infer<typeof prepareParams>;
      openStore: OpenResetStore;
      comparison: string;
    };
async function handleSavedAccount(
  options: GatewayRequestHandlerOptions,
  operation: Operation,
): Promise<void> {
  const { selection, openStore } = operation;
  const { agentId, profileId } = selection;
  const { context, signal, hasCurrentClientAuthority } = options;
  // Auth-reader disposal may replace the thrown error, but cannot undo admission or a reply.
  let resetAdmitted = false;
  let responded = false;
  const respond: GatewayRequestHandlerOptions["respond"] = (...args) => {
    responded = true;
    options.respond(...args);
  };
  const invalid = (message: string) =>
    respond(false, undefined, errorShape(ErrorCodes.INVALID_REQUEST, message));
  const config = context.getRuntimeConfig();
  if (!listAgentIds(config).includes(agentId)) {
    invalid("Unknown agent.");
    return;
  }
  const deadline = performance.now() + 20_000;
  const remainingMs = () => {
    const left = Math.ceil(deadline - performance.now());
    if (left <= 0) {
      throw new Error("Account request timed out.");
    }
    return left;
  };
  try {
    const agentDir = resolveAgentDir(config, agentId);
    const useAccount = async (
      preparedStore: AuthProfileStore,
      reader: { read?(): Promise<AuthProfileStore>; assertCurrent(): void },
    ) => {
      const store = structuredClone(preparedStore);
      const credential = store.profiles[profileId];
      if (!credential || credential.provider !== "openai" || credential.setup?.replacement) {
        invalid("Select an active Codex subscription login.");
        return;
      }
      if (!supportsCodexSubscriptionAuth(credential)) {
        invalid("This login does not provide Codex quota.");
        return;
      }
      const assertPrepared = () => {
        options.assertHandlerCurrent?.();
        if (
          signal?.aborted ||
          hasCurrentClientAuthority?.() === false ||
          context.getRuntimeConfig() !== config
        ) {
          throw new Error("Account credentials changed. Refresh Models and try again.");
        }
        reader.assertCurrent();
      };
      assertPrepared();
      const { start } = resolveCodexAppServerRuntimeOptions({
        pluginConfig: readCodexPluginConfig(config.plugins?.entries?.codex?.config),
      });
      if (isCodexAppServerProxyLaunch(start.args)) {
        throw new Error(
          "Account actions are unavailable through a Codex proxy. Configure a direct app-server launch.",
        );
      }
      // Pin the identity from the exact prepared native login, never a mutable
      // profile label, email, token fingerprint, or the usage payload alone.
      const quotaOnly = "quotaOnly" in selection && selection.quotaOnly;
      const prepareSnapshot = () =>
        resolveCodexAppServerPreparedAuthProfileSnapshot({
          agentDir,
          config,
          authProfileId: profileId,
          authProfileStore: store,
        });
      const snapshot =
        !quotaOnly && canSpendFromSettings(options, profileId)
          ? await prepareSnapshot()
          : undefined;
      const account = codexSubscriptionMember(snapshot?.loginParams);
      if (
        operation.kind !== "read" &&
        operation.selection.accountBinding !== account?.accountBinding
      ) {
        invalid("Reset not sent. Refresh Models and confirm the current subscription member.");
        return;
      }
      const session = {
        agentDir,
        config,
        signal,
        timeoutMs: remainingMs(),
        preparedAuth: {
          kind: "profile",
          profileId,
          store,
          snapshot: snapshot && account ? { ...snapshot, pinAccessToken: true as const } : snapshot,
        },
        authRequirement: "subscription",
        assertCurrent: assertPrepared,
        isolated: true,
        // Never log into the operator's native Codex home, remote server or shared daemon.
        startOptions: { ...start, transport: "stdio", homeScope: "agent" },
      } as const;
      const readLimits = () =>
        requestCodexAppServerJson({
          ...session,
          timeoutMs: remainingMs(),
          method: "account/rateLimits/read",
        });
      if (operation.kind !== "read") {
        const confirmedCredit = operation.selection;
        const journal = account && operation.openStore(assertPrepared);
        if (!journal || !account) {
          invalid("Reset not sent. Shared recovery is unavailable.");
          return;
        }
        if (operation.kind === "prepare") {
          const { head: previous, comparison } = await observeResetRecord(
            journal,
            account.accountBinding,
          );
          if (previous?.idempotencyKey === confirmedCredit.idempotencyKey) {
            if (previous.creditId !== confirmedCredit.creditId) {
              throw new Error("Credit selection changed.");
            }
          } else if (
            (previous && !previous.outcome) ||
            previous?.idempotencyKey !== confirmedCredit.afterReset
          ) {
            throw new Error("Refresh the current credit offer.");
          }
          assertPrepared();
          respond(true, operation.finish(comparison));
          return;
        }
        const result = await spendResetCredit({
          store: journal,
          accountBinding: account.accountBinding,
          selection: confirmedCredit,
          comparison: operation.comparison,
          assertCurrent: assertPrepared,
          verifyOffer: async () =>
            isResetCreditOffered(await readLimits(), account, confirmedCredit.creditId),
          onAdmitted: () => {
            resetAdmitted = true;
          },
          consume: (evidence) =>
            requestCodexAppServerJson({
              ...session,
              timeoutMs: remainingMs(),
              confirmedAccountReset: true,
              method: "account/rateLimitResetCredit/consume",
              requestParams: {
                creditId: confirmedCredit.creditId,
                idempotencyKey: confirmedCredit.idempotencyKey,
              },
              ...evidence,
            }),
        });
        respond(true, result);
        return;
      }
      // Ordinary quota reads keep their existing warm-notification path. Only fresh
      // offers from the pinned native session may authorize a new spend.
      let limits: unknown;
      let freshOffers: unknown;
      let stale = false;
      if (quotaOnly) {
        limits = (await readCachedCodexAppServerUsage(session))?.rateLimits;
        stale = Boolean(limits);
      } else {
        try {
          const selected = snapshot ?? (await prepareSnapshot());
          const fresh = account
            ? await readLimits()
            : (
                await readCodexAppServerUsage({
                  ...session,
                  preparedAuth: { ...session.preparedAuth, snapshot: selected },
                  freshOnly: true,
                })
              ).rateLimits;
          if (codexRateLimitsMatchWorkspace(fresh, selected?.chatgptAccountId)) {
            freshOffers = limits = fresh;
          }
        } catch (error) {
          assertPrepared();
          limits = (await readCachedCodexAppServerUsage(session).catch(() => undefined))
            ?.rateLimits;
          stale = Boolean(limits);
          if (!limits && !account) {
            throw new Error(quotaUnavailable, { cause: error });
          }
        }
      }
      let resetCredits;
      try {
        resetCredits = await readResetCreditBalance(
          freshOffers,
          account,
          account && openStore?.(assertPrepared),
        );
      } catch {
        // Journal failure disables spending, not ordinary quotas.
        resetCredits = await readResetCreditBalance(freshOffers, account);
      }
      const current = await reader.read?.();
      assertPrepared();
      if (current && !isDeepStrictEqual(current.profiles[profileId], credential)) {
        throw new Error("Account credentials changed. Refresh Models and try again.");
      }
      const usage = buildCodexAppServerUsageSnapshot(limits, { accountDetails: true });
      if (
        (account || !limits) &&
        usage.windows.length === 0 &&
        !usage.plan &&
        !usage.billing?.length
      ) {
        usage.error = quotaUnavailable;
      }
      respond(true, {
        updatedAt: Date.now(),
        providers: quotaOnly && !limits ? [] : [usage],
        ...(stale && { stale: true }),
        ...(resetCredits && { resetCredits }),
      });
    };
    if (isUserModelAuthProfileId(profileId)) {
      const handled = await withPersonalAuthProfileStore(profileId, async (owner) => {
        const store = await owner.read();
        const readCurrentCredential = owner.readCurrentCredential;
        await useAccount(store, {
          assertCurrent: () => {
            if (!isDeepStrictEqual(readCurrentCredential(), store.profiles[profileId])) {
              throw new Error("Account credentials changed. Refresh Models and try again.");
            }
          },
        });
        return true;
      });
      if (!handled) {
        invalid("Select a saved Codex subscription login.");
      }
    } else {
      await withAuthProfileStoreAtEffect(
        agentDir,
        {
          profileId,
          allowKeychainPrompt: false,
          config,
          externalCliProviderIds: ["openai"],
          externalCliProfileIds: [profileId],
        },
        async (reader) => useAccount(await reader.read(), reader),
      );
    }
  } catch (error) {
    if (responded) {
      return;
    }
    if (operation.kind !== "read" && !resetAdmitted) {
      invalid("Reset not sent. Refresh Models and check the selected subscription login.");
      return;
    }
    // A transport error after dispatch isn't a failed redemption. Do not retry here
    // or send raw provider diagnostics to the browser on the destructive path.
    respond(
      false,
      undefined,
      errorShape(
        ErrorCodes.UNAVAILABLE,
        operation.kind !== "read"
          ? "Reset not confirmed. Refresh the account's quota and credits before taking further action."
          : error instanceof Error
            ? error.message
            : "Codex usage unavailable. Try refreshing the account.",
      ),
    );
  }
}
