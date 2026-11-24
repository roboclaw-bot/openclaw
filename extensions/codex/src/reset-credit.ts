import { sha256Hex } from "openclaw/plugin-sdk/node-crypto-runtime";
import type { PluginStateKeyedStore } from "openclaw/plugin-sdk/plugin-state-runtime";
import { decodeOpenAICodexJwtPayload } from "openclaw/plugin-sdk/provider-oauth-runtime";
import { z } from "zod";
import type { CodexAppServerPreparedAuthProfileSnapshot } from "./app-server/auth-types.js";

export const creditId = z.string().min(1).max(512).regex(/\S/u);
const intent = z.object({ creditId, idempotencyKey: z.uuid() });
const resetResult = z.object({
  outcome: z.enum(["reset", "alreadyRedeemed", "nothingToReset", "noCredit"]),
});
// The local no-send receipt is terminal for this key; it is never accepted from the provider.
// Its wire label covers refusals both at offer verification and before native dispatch.
const receipt = intent.extend({ outcome: resetResult.shape.outcome.or(z.literal("notOffered")) });
const historyLimit = 8;
// Records from the original journal have no history; their current receipt stays readable.
const record = intent.extend({
  outcome: receipt.shape.outcome.optional(),
  history: z.array(receipt).max(historyLimit).optional(),
  submissions: z.int().positive().optional(),
});
export type ResetRecord = z.infer<typeof record>;
export type ResetStore = Pick<PluginStateKeyedStore<ResetRecord, 2>, "observe" | "compareAndApply">;

// Match Codex get_chatgpt_account_user_id: the selected workspace and its opaque membership.
const claimId = z
  .string()
  .min(1)
  .refine((value) => value === value.trim());
const tokenClaims = z.object({
  "https://api.openai.com/auth": z.object({
    chatgpt_account_id: claimId,
    chatgpt_account_user_id: claimId,
  }),
  "https://api.openai.com/profile": z.object({ email: z.string().optional() }).optional(),
});

/** Identify the credentials actually passed to Codex, not the profile row or its cached email. */
export function resetAccount(snapshot: CodexAppServerPreparedAuthProfileSnapshot | undefined) {
  const login = snapshot?.loginParams;
  if (login?.type !== "chatgptAuthTokens" || login.accessToken.split(".").length !== 3) {
    return undefined;
  }
  const claims = tokenClaims.safeParse(decodeOpenAICodexJwtPayload(login.accessToken));
  if (!claims.success) {
    return undefined;
  }
  const auth = claims.data["https://api.openai.com/auth"];
  const member = auth.chatgpt_account_user_id;
  const accountId = auth.chatgpt_account_id;
  if (accountId !== login.chatgptAccountId) {
    return undefined;
  }
  const email = claims.data["https://api.openai.com/profile"]?.email;
  return {
    memberId: member,
    workspaceId: accountId,
    accountEmail: email,
    accountBinding: sha256Hex(JSON.stringify(["codex-reset-credit", accountId, member])),
    accountLabel: [email, member, accountId].filter(Boolean).join(" · "),
  };
}

const creditSummary = z.object({
  accountId: z.string().nullish(),
  rateLimitResetCredits: z
    .object({
      availableCount: z.int().nonnegative(),
      credits: z.array(z.unknown()).nullish().catch(undefined),
    })
    .nullish(),
});
const availableCredit = z.object({
  id: creditId,
  status: z.literal("available"),
  resetType: z.literal("codexRateLimits"),
  expiresAt: z.int().nullable(),
  title: z.string().trim().max(256).nullish().catch(undefined),
});

type Account = NonNullable<ReturnType<typeof resetAccount>>;
type Summary = NonNullable<z.infer<typeof creditSummary>["rateLimitResetCredits"]>;
function availableOffers(summary: Summary | null | undefined) {
  const offers = new Map<string, { creditId: string; expiresAt: number | null; title?: string }>();
  if (summary?.availableCount) {
    for (const row of summary.credits ?? []) {
      const credit = availableCredit.safeParse(row);
      if (
        credit.success &&
        (credit.data.expiresAt === null || credit.data.expiresAt > Date.now() / 1_000)
      ) {
        const { id, expiresAt, title } = credit.data;
        offers.set(id, { creditId: id, expiresAt, ...(title && { title }) });
      }
    }
  }
  return [...offers.values()].toSorted(
    (a, b) =>
      (a.expiresAt ?? Infinity) - (b.expiresAt ?? Infinity) || a.creditId.localeCompare(b.creditId),
  );
}

export function isResetCreditOffered(value: unknown, account: Account, selected: string) {
  const { accountId, rateLimitResetCredits } = creditSummary.parse(value);
  if (!rateLimitResetCredits || (accountId != null && accountId !== account.workspaceId)) {
    throw new Error("Current subscription offers are unavailable.");
  }
  const offers = availableOffers(rateLimitResetCredits);
  if (offers.some((offer) => offer.creditId === selected)) {
    return true;
  }
  if (offers.length < rateLimitResetCredits.availableCount) {
    throw new Error("Credit details are incomplete.");
  }
  return false;
}
function receipts(head: ResetRecord | undefined) {
  if (!head) {
    return [];
  }
  const older = head.history ?? [];
  return head.outcome ? [receipt.parse(head), ...older].slice(0, historyLimit) : older;
}

export async function observeResetRecord(store: ResetStore, binding: string) {
  const observed = await store.observe(binding);
  return {
    head: observed.value === undefined ? undefined : record.parse(observed.value),
    comparison: observed.comparison,
  };
}

export async function readResetCreditBalance(
  value: unknown,
  account: Account | undefined,
  store?: ResetStore,
) {
  const parsed = creditSummary.safeParse(value);
  const summary = parsed.data?.rateLimitResetCredits;
  if (!account) {
    return summary ? { availableCount: summary.availableCount, readOnly: true } : undefined;
  }
  const usable =
    parsed.data?.accountId == null || parsed.data.accountId === account.workspaceId
      ? summary
      : undefined;
  const balance = { ...account, ...(usable && { availableCount: usable.availableCount }) };
  if (!store) {
    return { ...balance, journalUnavailable: true };
  }
  const { head: previous } = await observeResetRecord(store, account.accountBinding);
  const recentReceipts = receipts(previous);
  const spent = new Set(
    recentReceipts
      .filter((r) => r.outcome === "reset" || r.outcome === "alreadyRedeemed")
      .map((r) => r.creditId),
  );
  const offers = availableOffers(usable).filter((o) => !spent.has(o.creditId));
  const pending = previous && !previous.outcome ? intent.parse(previous) : undefined;
  return {
    ...balance,
    ...(offers.length && { offers }),
    ...(recentReceipts.length && { recentReceipts, lastReset: recentReceipts[0] }),
    ...(pending ? { pending } : offers[0] && { creditId: offers[0].creditId }),
  };
}

// One Gateway must not dispatch even an exact retry while the first call is still running.
// After a restart the durable intent, not this set, owns selection and provider idempotency.
const active = new Set<string>();
export async function spendResetCredit(params: {
  store: ResetStore;
  accountBinding: string;
  selection: z.infer<typeof intent> & { afterReset?: string };
  comparison: string;
  assertCurrent(): void;
  verifyOffer(): Promise<boolean>;
  onAdmitted(): void;
  consume(evidence: { onRequestWrite(): void; onIngressRejected(): void }): Promise<unknown>;
}) {
  const { accountBinding, selection, store } = params;
  if (active.has(accountBinding)) {
    throw new Error("A reset is already being submitted for this subscription.");
  }
  active.add(accountBinding);
  try {
    const { head: previous, comparison } = await observeResetRecord(store, accountBinding);
    const sameKey = previous && previous.idempotencyKey === selection.idempotencyKey;
    const submissions = sameKey ? (previous.submissions ?? 1) + 1 : undefined;
    const target = intent.parse(selection);
    const history = receipts(previous);
    const known = history.find((r) => r.idempotencyKey === target.idempotencyKey);
    if (known) {
      if (known.creditId !== target.creditId) {
        throw new Error("A retry cannot select another credit.");
      }
      return { outcome: known.outcome };
    }
    if (comparison !== params.comparison) {
      throw new Error("Another reset changed this subscription. Review it before confirming.");
    }
    if (sameKey) {
      if (previous.creditId !== selection.creditId) {
        throw new Error("A retry cannot select another credit.");
      }
      // A retry starts a new attempt on the same native key. Other dialogs opened against this pending state must review it again.
      params.onAdmitted(); // The previous dispatch may already have spent the credit.
      const retry = await store.compareAndApply(accountBinding, comparison, {
        operation: "update",
        action: "set",
        value: { ...previous, submissions },
      });
      if (retry.status !== "applied") {
        throw new Error("Another reset changed this subscription.");
      }
    } else {
      if ((previous && !previous.outcome) || previous?.idempotencyKey !== selection.afterReset) {
        throw new Error("Refresh the subscription before confirming a new reset.");
      }
      const alreadySpent = history.some(
        (r) =>
          r.creditId === target.creditId &&
          (r.outcome === "reset" || r.outcome === "alreadyRedeemed"),
      );
      const offered = !alreadySpent && (await params.verifyOffer());
      params.assertCurrent();
      const admission = await store.compareAndApply(accountBinding, comparison, {
        operation: "update",
        action: "set",
        // A refusal is also durable. An old request arriving later cannot turn
        // an explicitly unspent, no-longer-offered credit into a debit.
        value: { ...target, history, ...(!offered && { outcome: "notOffered" as const }) },
      });
      if (admission.status !== "applied") {
        throw new Error("Another reset changed this subscription.");
      }
      if (!offered) {
        return { outcome: "notOffered" as const };
      }
      params.onAdmitted();
    }
    // Pin settlement to this exact durable intent. A crash/lost result leaves it recoverable.
    const pending = await store.observe(accountBinding);
    if (
      pending.value?.outcome ||
      pending.value?.idempotencyKey !== target.idempotencyKey ||
      pending.value.creditId !== target.creditId ||
      pending.value.submissions !== submissions
    ) {
      throw new Error("Reset intent changed before dispatch.");
    }
    let mayHaveBeenEnqueued = false;
    let result: Pick<z.infer<typeof receipt>, "outcome">;
    try {
      params.assertCurrent();
      result = resetResult.parse(
        await params.consume({
          onRequestWrite() {
            mayHaveBeenEnqueued = true;
          },
          onIngressRejected() {
            mayHaveBeenEnqueued = false;
          },
        }),
      );
    } catch (error) {
      // No write, or a correlated native refusal before enqueue, can retire a new key.
      // Neither fact about this attempt disproves an earlier debit on a replay.
      if (mayHaveBeenEnqueued || sameKey) {
        throw error;
      }
      result = { outcome: "notOffered" };
    }
    const saved = await store.compareAndApply(accountBinding, pending.comparison, {
      operation: "update",
      action: "set",
      value: { ...pending.value, ...result },
    });
    if (saved.status !== "applied") {
      throw new Error("Reset receipt could not be recorded.");
    }
    return result;
  } finally {
    active.delete(accountBinding);
  }
}
