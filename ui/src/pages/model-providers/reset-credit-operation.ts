import { sha256 } from "@noble/hashes/sha2.js";
import { bytesToHex } from "@noble/hashes/utils.js";
import {
  GatewayProtocolRequestTimeoutError,
  isGatewayProtocolResponseError,
} from "@openclaw/gateway-client/browser";
import { asOptionalRecord } from "@openclaw/normalization-core/record-coerce";
import {
  isGatewayRestartUnavailableError,
  isGatewaySuspendUnavailableError,
} from "../../../../packages/gateway-protocol/src/restart-unavailable.ts";
import { createChangeListeners } from "../../../../src/shared/listeners.js";
import type { GatewayBrowserClient } from "../../api/gateway.ts";
import { getSafeSessionStorage } from "../../local-storage.ts";

export const CODEX_ACCOUNT_REQUEST_TIMEOUT_MS = 30_000;

type Outcome = "reset" | "alreadyRedeemed" | "noCredit" | "nothingToReset" | "notOffered";
export type ResetIntent = { creditId: string; idempotencyKey: string };
type Receipt = ResetIntent & { outcome: Outcome };
export type ResetCreditBalance = {
  availableCount?: number;
  creditId?: string;
  accountBinding?: string;
  accountLabel?: string;
  accountEmail?: string;
  workspaceId?: string;
  memberId?: string;
  readOnly?: boolean;
  offers?: { creditId: string; expiresAt: number | null; title?: string }[];
  recentReceipts?: Receipt[];
  journalUnavailable?: boolean;
  pending?: ResetIntent;
  lastReset?: Receipt;
};
export function hasResetIdentity(balance?: ResetCreditBalance): balance is ResetCreditBalance & {
  accountBinding: string;
  accountLabel: string;
  workspaceId: string;
  memberId: string;
} {
  return Boolean(
    balance?.accountBinding?.trim() &&
    balance.accountLabel?.trim() &&
    balance.workspaceId?.trim() &&
    balance.memberId?.trim(),
  );
}
// null records an observed empty journal. Missing means the predecessor was never recorded.
type ResetTarget = ResetIntent & { afterReset?: string | null };
export type ResetAttempt = ResetTarget & {
  phase: Outcome | "pending" | "uncertain" | "denied";
};
export type ResetOperation = ReturnType<typeof createOperation>;
export type ResetRegistry = ReturnType<typeof createRegistry>;
const applications = new WeakMap<object, Map<string, ResetRegistry>>();

export function resetRegistryFor(application: object, gatewayUrl: string, principal: string) {
  if (!principal || !gatewayUrl) {
    return undefined;
  }
  const scopes = applications.get(application) ?? new Map<string, ResetRegistry>();
  applications.set(application, scopes);
  const scope = JSON.stringify([gatewayUrl, principal]);
  let registry = scopes.get(scope);
  if (!registry) {
    registry = createRegistry(scope);
    scopes.set(scope, registry);
  }
  return registry;
}

function createRegistry(scope: string) {
  let revision = 0;
  const subscriptions = new Map<string, ResetOperation>();
  return {
    get revision() {
      return revision;
    },
    observe(balance: ResetCreditBalance | undefined, readAt: number) {
      if (!hasResetIdentity(balance)) {
        return undefined;
      }
      const binding = balance.accountBinding;
      let operation = subscriptions.get(binding);
      if (!operation) {
        // Do not persist a gateway URL (possibly credential-bearing) or a human label.
        const key = bytesToHex(sha256(new TextEncoder().encode(JSON.stringify([scope, binding]))));
        operation = createOperation(
          binding,
          `openclaw.control.codexReset.v2:${key}`,
          () => ++revision,
        );
        subscriptions.set(binding, operation);
      }
      const local = operation.current;
      const matches = (r?: Receipt) =>
        r?.creditId === local?.creditId && r?.idempotencyKey === local?.idempotencyKey;
      const receipt =
        !balance.journalUnavailable && local
          ? (balance.recentReceipts?.find(matches) ??
            (matches(balance.lastReset) ? balance.lastReset : undefined))
          : undefined;
      if (operation.revision > readAt && !receipt) {
        return { operation }; // This read predates the latest local request; it cannot authorize a new spend.
      }
      if (receipt) {
        operation.settle(receipt);
      }
      return { operation, observed: operation.current };
    },
  };
}

function createOperation(accountBinding: string, storageKey: string, advance: () => number) {
  const changes = createChangeListeners();
  const completions = createChangeListeners();
  let revision = 0;
  let current: ResetAttempt | undefined;
  let retryingShared = false;
  try {
    const raw = getSafeSessionStorage()?.getItem(storageKey);
    if (raw) {
      const { creditId, idempotencyKey, afterReset } = JSON.parse(raw);
      const uuid = /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i;
      if (
        typeof creditId === "string" &&
        creditId &&
        typeof idempotencyKey === "string" &&
        uuid.test(idempotencyKey)
      ) {
        current = {
          creditId,
          idempotencyKey,
          afterReset:
            afterReset === null || (typeof afterReset === "string" && uuid.test(afterReset))
              ? afterReset
              : undefined,
          phase: "uncertain",
        };
      }
    }
  } catch {
    // Storage may be unavailable. The Gateway owns admitted intents across tabs.
  }
  function publish(attempt: ResetAttempt) {
    current = attempt;
    revision = advance();
    try {
      const storage = getSafeSessionStorage();
      if (attempt.phase === "pending" || attempt.phase === "uncertain") {
        const { creditId, idempotencyKey, afterReset } = attempt;
        storage?.setItem(storageKey, JSON.stringify({ creditId, idempotencyKey, afterReset }));
      } else {
        storage?.removeItem(storageKey);
      }
    } catch {
      // Keep this tab's in-memory recovery if browser persistence is unavailable.
    }
    changes.publish();
  }
  return {
    subscribe: changes.subscribe,
    onResult: completions.subscribe,
    get retryingShared() {
      return retryingShared;
    },
    get current() {
      return current;
    },
    get revision() {
      return revision;
    },
    settle(receipt: Receipt) {
      // Only an exact positive receipt settles an interrupted request. Absence, a different
      // pending key, and an unavailable journal say nothing about the original outcome.
      if (current?.phase !== receipt.outcome) {
        publish({ ...receipt, phase: receipt.outcome });
      }
    },
    async spend(
      client: GatewayBrowserClient,
      row: { agentId: string; profileId: string },
      target: ResetTarget,
      confirmationId: string,
      observed: ResetAttempt | undefined,
      retry: boolean,
    ) {
      if (retryingShared || current !== observed || current?.phase === "pending") {
        return;
      }
      const admitted = { ...target, phase: "pending" } as const;
      // A shared retry already has a Gateway journal entry. Keep our unknown request
      // until the user confirms an independent spend; then track that new intent instead.
      const preserveLocal =
        retry &&
        current?.phase === "uncertain" &&
        (current.creditId !== target.creditId || current.idempotencyKey !== target.idempotencyKey);
      if (preserveLocal) {
        retryingShared = true;
        changes.publish();
      } else {
        publish(admitted);
      }
      let phase: ResetAttempt["phase"];
      let sent = false;
      try {
        const { outcome } = await client.request<{ outcome: Outcome }>(
          "codex.consumeResetCredit",
          {
            agentId: row.agentId,
            profileId: row.profileId,
            accountBinding,
            creditId: target.creditId,
            idempotencyKey: target.idempotencyKey,
            ...(target.afterReset && { afterReset: target.afterReset }),
            confirmationId,
          },
          {
            timeoutMs: CODEX_ACCOUNT_REQUEST_TIMEOUT_MS,
            onSent: () => {
              sent = true;
            },
          },
        );
        phase = outcome;
      } catch (error) {
        // A failed retry never disproves the original journaled request. After dispatch,
        // only a correlated refusal or the transport's explicit unsent deadline is definitive.
        const notSent = isGatewayProtocolResponseError(error)
          ? error.gatewayCode === "FORBIDDEN" ||
            error.gatewayCode === "INVALID_REQUEST" ||
            (error.gatewayCode === "UNAVAILABLE" &&
              error.retryable &&
              (isGatewayRestartUnavailableError(error) ||
                isGatewaySuspendUnavailableError(error) ||
                asOptionalRecord(error.details)?.reason === "request-start-timeout"))
          : error instanceof GatewayProtocolRequestTimeoutError
            ? !error.requestSent
            : !sent;
        phase = !retry && notSent ? "denied" : "uncertain";
      }
      // A read can already have settled this exact receipt; a late transport answer
      // must not clear a newer intent or replace its visible outcome.
      if (preserveLocal) {
        retryingShared = false;
        changes.publish();
        completions.publish(); // Read B’s journal; its transport result does not settle A.
      } else if (current === admitted) {
        publish({ ...target, phase });
        completions.publish();
      }
    },
  };
}
