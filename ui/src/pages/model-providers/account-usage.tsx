// Codex reports plan limits per signed-in account, so each OpenAI account row
// reads its own; the page's forced refresh advances the revision.
import { createMemo, createSignal, Loading, onCleanup, onSettled, refresh, Show } from "solid-js";
import type {
  ProviderUsageSnapshot,
  UsageSummary,
} from "../../../../src/infra/provider-usage.types.js";
import type { GatewayBrowserClient } from "../../api/gateway.ts";
import type { ApplicationContext } from "../../app/context.ts";
import {
  hasProviderUsageDetails,
  ProviderUsagePanel,
} from "../../components/solid/provider-usage.tsx";
import { formatUiError } from "../../lib/format-error.ts";
import { canCallGatewayMethod, isGatewayMethodAdvertised } from "../../lib/gateway-methods.ts";
import { modelAuthEventInvalidates } from "../../lib/model-auth-request-state.ts";
import { modelCatalogEventInvalidation } from "../../lib/model-catalog-cache.ts";
import { formatUsageWindowLabel } from "../../lib/provider-quota-summary.ts";
import { formatDateTimeMs, formatTimeMs } from "../../lib/reactive/format.ts";
import { t } from "../../lib/reactive/i18n.ts";
import { createTimeout } from "../../lib/reactive/timers.ts";
import { showToast } from "../../lib/toast.ts";
import {
  AccountResetCredits,
  type CreditColumn,
  type SubmitReset,
} from "./account-reset-credits.tsx";
import type { ModelProvidersData } from "./load.ts";
import type { ModelProvidersState } from "./page-state.ts";
import {
  CODEX_ACCOUNT_REQUEST_TIMEOUT_MS,
  resetNeedsAttention,
  resetRegistryFor,
  type ResetCreditBalance,
  type ResetRegistry,
  type ResetOperation,
  type ResetAttempt,
} from "./reset-credit-operation.ts";

// The Codex account-details contract reports a numeric balance independently of quota windows.
export function accountCreditBalance(snapshot?: ProviderUsageSnapshot) {
  const balance = snapshot?.billing?.find(
    (entry) => entry.type === "balance" && entry.unit === "credits" && !entry.label,
  );
  return balance?.type === "balance" ? balance : undefined;
}

export type AccountUsageScope = {
  client: GatewayBrowserClient;
  agentId: string;
  revision: number;
  credentialRevision?: number | "pending" | "unavailable";
  generation: number;
  registry?: ResetRegistry;
  cacheAvailable: boolean;
  canConsume: () => boolean;
};

// The Gateway publishes at agent scope, not profile scope. Keep headings mounted, but never
// present member data until an inventory read *started after* its last credential publication.
export function createAccountUsageInventory(
  context: ApplicationContext,
  page: ModelProvidersState,
  notify: () => void,
) {
  let published = 0,
    reading = 0,
    verified = 0;
  const retire = () => {
    published++;
    notify();
  };
  return {
    get stale() {
      return verified !== published;
    },
    subscribe(refreshPage: () => void) {
      return context.gateway.subscribeEvents((event) => {
        const id = page.selectedAgentId;
        const change = modelCatalogEventInvalidation(event, { agentId: id });
        if (!change) {
          return;
        }
        // Selection, discovery and availability-only updates do not replace credentials.
        if (change === "refresh" && modelAuthEventInvalidates(event, id)) {
          retire();
        }
        refreshPage();
      });
    },
    signedIn(providerId?: string) {
      if (providerId === "openai") {
        retire();
      }
    },
    begin() {
      reading = published;
    },
    complete(data: ModelProvidersData) {
      // A failed targeted refresh retains the old inventory only for presentation.
      if (data.authStatus && !data.error) {
        verified = reading;
      }
    },
    reset() {
      verified = published;
    },
    scope(loading: boolean): AccountUsageScope | null {
      const { selectedAgentId: agentId, accountUsageRevision: revision } = page;
      const snapshot = context.gateway.snapshot;
      const client = snapshot.client;
      if (
        !client ||
        !agentId ||
        !canCallGatewayMethod(snapshot, "codex.accountUsage", "operator.admin")
      ) {
        return null;
      }
      const principal = () =>
        context.gateway.snapshot.hello?.auth?.recoveryScope ||
        (client.recoveryScopeReady && client.recoveryScope) ||
        "";
      const authenticatedScope = principal();
      const generation = client.connectionGeneration;
      const credentialRevision =
        verified === published
          ? verified
          : page.data?.error && !loading
            ? "unavailable"
            : "pending";
      const gatewayUrl = context.gateway.connection.gatewayUrl;
      return {
        generation,
        credentialRevision,
        cacheAvailable: isGatewayMethodAdvertised(snapshot, "codex.prepareResetCredit") === true,
        registry: resetRegistryFor(context.gateway, gatewayUrl, authenticatedScope),
        client,
        agentId,
        revision,
        canConsume: () => {
          const live = context.gateway.snapshot;
          return (
            credentialRevision === published &&
            live.client === client &&
            client.connectionGeneration === generation &&
            authenticatedScope === principal() &&
            context.settingsAgentSelection.state.selectedId === agentId &&
            canCallGatewayMethod(live, "codex.prepareResetCredit", "operator.admin") &&
            canCallGatewayMethod(live, "codex.consumeResetCredit", "operator.admin")
          );
        },
      };
    },
  };
}

function AccountReading(props: {
  snapshot: ProviderUsageSnapshot;
  grouped?: boolean;
  reportsResetCredits: boolean;
}) {
  const balance = createMemo(() => accountCreditBalance(props.snapshot));
  const details = createMemo(() => ({
    windows: props.snapshot.windows.filter((window) => window.groupLabel),
    // Only this account's ordinary credit balance is displayed in whole credits.
    billing: props.snapshot.billing?.flatMap((entry) => {
      if (entry.type !== "balance" || entry !== balance()) {
        return [entry];
      }
      return props.grouped
        ? []
        : [
            {
              ...entry,
              label: t("modelProviders.limits.credits"),
              amount: Math.sign(entry.amount) * Math.round(Math.abs(entry.amount)),
            },
          ];
    }),
    costHistory: props.snapshot.costHistory,
  }));
  const primary = createMemo(() => ({
    windows: props.grouped ? [] : props.snapshot.windows.filter((window) => !window.groupLabel),
    // The comparison already reports failed and partial readings beside the affected account.
    error: props.grouped ? undefined : props.snapshot.error,
    summary: props.snapshot.summary,
  }));
  return (
    <>
      <Show when={hasProviderUsageDetails(primary())}>
        <ProviderUsagePanel compact usage={primary()} />
      </Show>
      <Show when={props.snapshot.plan && (props.grouped || !hasProviderUsageDetails(details()))}>
        <span class="model-providers__account-plan">{props.snapshot.plan}</span>
      </Show>
      <Show when={hasProviderUsageDetails(details())}>
        <Show
          when={props.grouped}
          fallback={
            <details class="model-providers__account-details">
              <summary>
                {t("modelProviders.limits.accountDetails")}
                {props.snapshot.plan ? ` · ${props.snapshot.plan}` : ""}
              </summary>
              <ProviderUsagePanel compact usage={details()} />
            </details>
          }
        >
          <ProviderUsagePanel compact usage={details()} />
        </Show>
      </Show>
      <Show
        when={
          !props.reportsResetCredits &&
          !props.snapshot.plan &&
          !hasProviderUsageDetails(props.snapshot)
        }
      >
        <span>{t("modelProviders.noStats")}</span>
      </Show>
    </>
  );
}

type AccountKey = Pick<
  AccountUsageScope,
  "client" | "agentId" | "registry" | "generation" | "credentialRevision"
> & {
  profileId: string;
};
type Reading = {
  account: AccountKey;
  loading?: true;
  refreshing?: boolean;
  // Presentation only: status of a user-confirmed request if the next quota read fails.
  confirmed?: ResetAttempt["phase"];
  stale?: boolean;
  snapshot?: ProviderUsageSnapshot;
  error?: string;
  resetCredits?: ResetCreditBalance;
  nextReset?: { at: number; label: string };
  operation?: ResetOperation;
  observed?: ResetAttempt;
};
type Answer = UsageSummary & { stale?: boolean; resetCredits?: ResetCreditBalance };

// Headings, segments, and the selected details share the same profile-scoped read.
export function createAccountUsage(scope: () => AccountUsageScope, readProfileId: () => string) {
  const account = createMemo(
    () => {
      const { client, agentId, generation, registry, credentialRevision } = scope();
      return {
        client,
        agentId,
        profileId: readProfileId(),
        generation,
        registry,
        credentialRevision,
      };
    },
    {
      equals: (a, b) =>
        a.client === b.client &&
        a.agentId === b.agentId &&
        a.profileId === b.profileId &&
        a.registry === b.registry &&
        a.credentialRevision === b.credentialRevision &&
        a.generation === b.generation,
    },
  );
  const revision = createMemo(() => scope().revision);
  const cacheAvailable = createMemo(() => scope().cacheAvailable);
  const result = createMemo<Reading>((previous) => {
    const key = account();
    if (key.credentialRevision === "pending") {
      return { account: key, loading: true };
    }
    if (key.credentialRevision === "unavailable") {
      return { account: key, error: t("usage.providerUsage.unavailable") };
    }
    revision();
    const { client, registry, agentId, profileId } = key;
    const readAt = registry?.revision ?? 0;
    const controller = new AbortController();
    onCleanup(() => controller.abort());
    const options = { signal: controller.signal, timeoutMs: CODEX_ACCOUNT_REQUEST_TIMEOUT_MS };
    const params = { agentId, profileId };
    const detail = client.request<Answer>("codex.accountUsage", params, options).then(
      (answer) => ({ kind: "detail" as const, answer }),
      (error: unknown) => ({ kind: "error" as const, error: formatUiError(error) }),
    );
    const first = cacheAvailable()
      ? Promise.race([
          detail,
          client
            .request<UsageSummary>("codex.accountUsage", { ...params, quotaOnly: true }, options)
            .then(
              (answer) => ({ kind: "cache" as const, snapshot: answer.providers[0] }),
              () => ({ kind: "cache" as const, snapshot: undefined }),
            ),
        ])
      : detail;
    return (async function* () {
      // An ordinary refresh can retain quota and an unchanged confirmation. Hide unresolved
      // debit status while the Gateway verifies its member again.
      const prior = previous?.account === key ? previous : undefined;
      const phase = prior?.operation?.current?.phase;
      const initial: Reading =
        phase === "pending" || phase === "uncertain"
          ? { ...prior, account: key, resetCredits: undefined }
          : (prior ?? { account: key, loading: true });
      yield { ...initial, refreshing: true };
      const early = await first;
      const cache = early.kind === "cache" ? early.snapshot : undefined;
      // Cache updates quota only. It cannot create credit authority or retire an unchanged dialog.
      if (cache) {
        yield { ...initial, loading: undefined, snapshot: cache, stale: true, refreshing: true };
      }
      const final = early.kind === "cache" ? await detail : early;
      // A fresh reading has already reflected its observed attempt. A later, unrelated
      // quota outage must not turn that old success back into account-row feedback.
      const unrefreshedOutcome = () => {
        const local = prior?.operation?.current;
        return local && (local !== prior?.observed || resetNeedsAttention(local.phase))
          ? local.phase
          : prior?.confirmed;
      };
      if (final.kind === "error") {
        const operation = prior?.operation;
        const outcome = unrefreshedOutcome();
        yield {
          account: key,
          error: final.error,
          // Retain only the member and outstanding result, never offers from the failed read.
          operation: outcome || operation?.retryingShared ? operation : undefined,
          confirmed: outcome,
          snapshot: cache,
          stale: Boolean(cache),
        };
        return;
      }
      const { providers, resetCredits, stale } = final.answer;
      const blocking = providers.flatMap((p) => p.windows).filter((w) => w.usedPercent >= 100);
      const window = blocking.length === 1 ? blocking[0] : undefined;
      const nextReset =
        !stale && window?.resetAt && window.resetAt > Date.now()
          ? {
              at: window.resetAt,
              label: [window.groupLabel, formatUsageWindowLabel(window.label)]
                .filter(Boolean)
                .join(" · "),
            }
          : undefined;
      const observed = !controller.signal.aborted
        ? registry?.observe(resetCredits, readAt)
        : undefined;
      yield {
        account: key,
        snapshot: providers[0],
        stale,
        nextReset,
        resetCredits,
        ...observed,
        confirmed:
          (stale || providers[0]?.error !== undefined) &&
          observed?.operation &&
          observed.operation === prior?.operation
            ? unrefreshedOutcome()
            : undefined,
      };
    })();
  });
  const refreshReading = () => void refresh(result);
  const onResetResult = () => {
    if (scope().canConsume()) {
      refreshReading();
    }
  };
  const reading = createMemo(() => {
    const value = result();
    // Reconcile the balance even if the operator collapsed or switched details after sending.
    onSettled(() => value.operation?.onResult(onResetResult));
    return value;
  });
  return {
    account,
    result: reading,
    canConsume: () => scope().canConsume(),
    refresh: refreshReading,
  };
}
export type AccountUsageRead = ReturnType<typeof createAccountUsage>;

export function AccountCreditControls(props: { read: AccountUsageRead; column?: CreditColumn }) {
  return (
    <Show when={props.read.account()} keyed>
      {(target) => {
        const feedback = new AbortController();
        onSettled(() => () => feedback.abort());
        const spend: SubmitReset = async (selection, ticket, observed, creditId) => {
          const op = props.read.result().operation;
          const retry = selection.action === "retry";
          const outcome = await op?.spend(
            target.client,
            target,
            { creditId, idempotencyKey: ticket.idempotencyKey, afterReset: selection.afterReset },
            ticket.confirmationId,
            observed,
            retry,
          );
          // Only this account's initiating action notifies, never a journal read or a peer.
          if (
            !outcome ||
            feedback.signal.aborted ||
            !props.read.canConsume() ||
            op !== props.read.result().operation
          ) {
            return;
          }
          showToast({
            severity: outcome === "reset" ? "success" : "info",
            message: t(
              retry && outcome === "reset"
                ? "modelProviders.resetCredits.retryConfirmed"
                : `modelProviders.resetCredits.${outcome}`,
            ),
            description: props.column?.name ?? selection.accountEmail ?? selection.accountLabel,
            signal: feedback.signal,
          });
        };
        return (
          <AccountResetCredits
            account={target}
            summary={props.read.result()}
            column={props.column}
            canConsume={props.read.canConsume}
            refresh={props.read.refresh}
            onSpend={spend}
          >
            <WindowResetHint next={props.read.result().nextReset} />
          </AccountResetCredits>
        );
      }}
    </Show>
  );
}

export function AccountLimits(props: { read: AccountUsageRead; grouped?: boolean }) {
  const result = () => props.read.result();
  const reportsResetCredits = () => result().resetCredits?.availableCount !== undefined;
  const emptyMessage = () => {
    const { loading, error } = result();
    if (loading || error !== undefined) {
      return props.grouped
        ? undefined
        : error || t(loading ? "common.loading" : "usage.providerUsage.unavailable");
    }
    return reportsResetCredits() ? undefined : t("modelProviders.noStats");
  };
  return (
    <div class="model-providers__account-limits">
      <Loading
        on={props.read.account()}
        fallback={props.grouped ? undefined : <span>{t("common.loading")}</span>}
      >
        <Show when={!props.grouped && result().stale}>
          <span>{t("modelProviders.resetCredits.cachedQuota")}</span>
        </Show>
        <Show when={!props.grouped && result().snapshot && result().error}>
          {(error) => <span class="provider-usage__error">{error()}</span>}
        </Show>
        <Show
          when={result().snapshot}
          fallback={
            <Show when={emptyMessage()}>
              {(message) => (
                <span class={result().error ? "provider-usage__error" : undefined}>
                  {message()}
                </span>
              )}
            </Show>
          }
        >
          {(snapshot) => (
            <AccountReading
              snapshot={snapshot()}
              grouped={props.grouped}
              reportsResetCredits={reportsResetCredits()}
            />
          )}
        </Show>
        <Show when={!props.grouped}>
          <AccountCreditControls read={props.read} />
        </Show>
      </Loading>
    </div>
  );
}

function WindowResetHint(props: { next?: { at: number; label: string } }) {
  const [now, setNow] = createSignal(Date.now());
  createTimeout(
    () => setNow(Date.now()),
    () =>
      props.next && props.next.at > now()
        ? Math.min(2_147_483_647, Math.max(0, props.next.at - Date.now()))
        : undefined,
  );
  return (
    <Show
      when={props.next && props.next.at > now() && props.next}
      fallback={<p>{t("modelProviders.resetCredits.alternative")}</p>}
    >
      {(next) => (
        <p>
          {new Date(next().at).toDateString() === new Date(now()).toDateString()
            ? t("modelProviders.resetCredits.nextReset", {
                window: next().label,
                time: formatTimeMs(next().at),
              })
            : t("modelProviders.resetCredits.nextResetOnDate", {
                window: next().label,
                date: formatDateTimeMs(next().at, { dateStyle: "medium" }),
                time: formatTimeMs(next().at),
              })}
        </p>
      )}
    </Show>
  );
}
