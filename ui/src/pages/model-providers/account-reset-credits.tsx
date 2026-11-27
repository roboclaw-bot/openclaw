import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, For, onSettled, Show } from "solid-js";
import { ModalDialog, type OpenClawModalDialog } from "../../components/modal-dialog.tsx";
import { DialogHeader } from "../../components/solid/dialog-header.tsx";
import { formatDateTimeMs, formatNumber } from "../../lib/reactive/format.ts";
import { t } from "../../lib/reactive/i18n.ts";
import { listen } from "../../lib/reactive/listener.ts";
import { observeState } from "../../lib/reactive/observe-state.ts";
import { projectOwner } from "../../lib/reactive/projection.ts";
import { createInterval, createTimeout } from "../../lib/reactive/timers.ts";
import { generateUUID } from "../../lib/uuid.ts";
import type { AccountUsageRead } from "./account-usage.tsx";
import {
  CODEX_ACCOUNT_REQUEST_TIMEOUT_MS,
  hasResetIdentity,
  resetReceiptOutcome,
  type ResetAttempt,
  type ResetIntent,
} from "./reset-credit-operation.ts";

type Account = ReturnType<AccountUsageRead["account"]>;
type Summary = ReturnType<AccountUsageRead["result"]>;
export type CreditColumn = { name: string; translate?: string; grabbed: boolean };
type Offer = { creditId: string; expiresAt?: number | null; title?: string };
type Selection = {
  accountBinding: string;
  accountLabel: string;
  accountEmail?: string;
  memberId: string;
  workspaceId: string;
  choices: Offer[];
  idempotencyKey?: string;
  afterReset?: string | null;
  unresolved?: ResetAttempt;
  action: "use" | "retry" | "newSpend";
};
type Prepared = {
  confirmationId: string;
  idempotencyKey: string;
  waitMs: number;
  expiresInMs: number;
};
const uuid = /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i;

export type SubmitReset = (
  selection: Selection,
  ticket: Prepared,
  observed: ResetAttempt | undefined,
  creditId: string,
) => void;

export function AccountResetCredits(props: {
  onSpend: SubmitReset;
  account: Account;
  summary: Summary;
  column?: CreditColumn;
  children: JSX.Element;
  canConsume: () => boolean;
  refresh: () => void;
}) {
  const owner = () => props.summary.operation;
  const projection = createMemo(() => {
    const source = props.summary.resetCredits && owner();
    return source && projectOwner(source, (op) => op.current);
  });
  const attempt = () => projection()?.read();
  const balance = () => props.summary.resetCredits;
  const journal = () => {
    const value = balance();
    return hasResetIdentity(value) ? value : undefined;
  };
  const fresh = () =>
    !props.summary.error && props.summary.observed === attempt() && !owner()?.retryingShared;
  const own = (intent?: ResetIntent) =>
    Boolean(
      intent &&
      intent.creditId === attempt()?.creditId &&
      intent.idempotencyKey === attempt()?.idempotencyKey,
    );
  const activity = () =>
    Boolean(
      props.summary.confirmed ||
      attempt() ||
      journal()?.pending ||
      journal()?.lastReset ||
      journal()?.journalUnavailable,
    );
  // The registry has already checked for an exact receipt. A different journal head
  // rules out a local retry against the old predecessor, not a debit of this credit.
  const superseded = createMemo(() => {
    const local = attempt();
    const credits = journal();
    return local?.phase === "uncertain" &&
      !credits?.pending &&
      credits?.lastReset &&
      local.afterReset !== credits.lastReset.idempotencyKey
      ? local
      : undefined;
  });
  const offers = createMemo(() => {
    const credits = journal();
    if (!credits) {
      return [];
    }
    const candidates: Offer[] =
      credits.offers ?? (credits.creditId ? [{ creditId: credits.creditId }] : []);
    const local = attempt();
    return candidates.filter(
      (o) =>
        o.creditId !== superseded()?.creditId &&
        !(
          local?.creditId === o.creditId &&
          (local.phase === "alreadyRedeemed" || local.phase === "reset")
        ) &&
        !(
          credits.lastReset?.creditId === o.creditId &&
          (credits.lastReset.outcome === "alreadyRedeemed" || credits.lastReset.outcome === "reset")
        ),
    );
  });
  const target = createMemo<Selection | undefined>(
    () => {
      const credits = journal();
      if (
        !owner() ||
        !credits ||
        credits.readOnly ||
        credits.journalUnavailable ||
        !props.canConsume()
      ) {
        return undefined;
      }
      const local = attempt();
      const retry = credits.pending ?? (local?.phase === "uncertain" ? local : undefined);
      const { accountLabel, accountBinding, accountEmail, workspaceId, memberId } = credits;
      const identity = { accountLabel, accountBinding, accountEmail, workspaceId, memberId };
      if (retry && !superseded()) {
        const offer = offers().find((o) => o.creditId === retry.creditId);
        // Only retry the original intent against its unchanged predecessor. If its credit
        // expired, the Gateway verifies the live offer and records no spend; never switch IDs.
        if (
          !credits.pending &&
          (!fresh() ||
            credits.availableCount === undefined ||
            local?.afterReset !== (credits.lastReset?.idempotencyKey ?? null))
        ) {
          return undefined;
        }
        return {
          ...identity,
          choices: [offer ?? { creditId: retry.creditId }],
          afterReset: own(retry) ? local?.afterReset : undefined,
          idempotencyKey: retry.idempotencyKey,
          action: "retry",
        };
      }
      if (!offers().length || (credits.availableCount ?? 0) <= 0) {
        return undefined;
      }
      const last = credits.lastReset;
      return {
        ...identity,
        choices: offers(),
        afterReset: last?.idempotencyKey ?? null,
        unresolved: superseded(),
        action: last || local ? "newSpend" : "use",
      };
    },
    {
      equals: (a, b) =>
        a?.accountBinding === b?.accountBinding &&
        a?.accountLabel === b?.accountLabel &&
        a?.accountEmail === b?.accountEmail &&
        a?.memberId === b?.memberId &&
        a?.workspaceId === b?.workspaceId &&
        a?.choices.length === b?.choices.length &&
        !a?.choices.some(
          (offer, i) =>
            offer.creditId !== b?.choices[i]?.creditId ||
            offer.title !== b?.choices[i]?.title ||
            offer.expiresAt !== b?.choices[i]?.expiresAt,
        ) &&
        a?.idempotencyKey === b?.idempotencyKey &&
        a?.afterReset === b?.afterReset &&
        a?.action === b?.action &&
        a?.unresolved === b?.unresolved,
    },
  );
  const localPhase = () => attempt()?.phase ?? props.summary.confirmed;
  const localReceipt = () => resetReceiptOutcome(localPhase());
  const attention = () => !localReceipt() && localPhase();
  const accountReceipt = () => {
    const last = journal()?.lastReset;
    return last && (!own(last) || last.outcome !== localReceipt()) ? last : undefined;
  };
  const accountPending = () => {
    const pending = journal()?.pending;
    return pending && (!own(pending) || (attention() !== "pending" && attention() !== "uncertain"));
  };
  const needsRefresh = () =>
    Boolean(
      (props.summary.error && activity()) ||
      attention() === "uncertain" ||
      attention() === "denied" ||
      journal()?.pending ||
      journal()?.journalUnavailable ||
      (attempt() && !fresh() && !props.summary.refreshing && attention() !== "pending"),
    );
  let cell!: HTMLDivElement;
  return (
    <>
      <Show
        when={props.column || balance()?.availableCount !== undefined || target() || activity()}
      >
        <div
          ref={(node) => {
            cell = node;
          }}
          tabindex="-1"
          class={props.column ? "model-providers__credit" : "model-providers__reset-credits"}
          data-grabbed={props.column?.grabbed || undefined}
          style={{ "--credit-translate": props.column?.translate }}
        >
          <Show
            when={props.column}
            fallback={
              <Show when={balance()?.availableCount !== undefined}>
                <strong>
                  {t("modelProviders.resetCredits.balance", {
                    count: formatNumber(balance()!.availableCount!),
                  })}
                </strong>
              </Show>
            }
          >
            {(column) => (
              <>
                <span class="settings-control__sr-label">
                  {column().name}:{" "}
                  {balance()?.availableCount ?? t("modelProviders.limits.notReported")}
                </span>
                <span aria-hidden="true">{balance()?.availableCount ?? "—"}</span>
              </>
            )}
          </Show>
          <Show
            when={target()}
            keyed
            fallback={
              <Show when={!props.column && !activity() && (balance()?.availableCount ?? 0) > 0}>
                <span>
                  {t(
                    balance()?.readOnly || balance()?.creditId || balance()?.offers?.length
                      ? "modelProviders.resetCredits.readOnly"
                      : "modelProviders.resetCredits.countOnly",
                  )}
                </span>
              </Show>
            }
          >
            {(selected) => (
              <CreditAction
                selection={selected}
                name={props.column?.name}
                account={props.account}
                refresh={props.refresh}
                ready={() =>
                  props.canConsume() &&
                  target() === selected &&
                  fresh() &&
                  (!props.column || !props.summary.stale) &&
                  attempt()?.phase !== "pending"
                }
                observed={() => owner()?.current}
                onSpend={(ticket, observed, creditId) =>
                  props.onSpend(selected, ticket, observed, creditId)
                }
                status={() => cell}
              >
                {props.children}
              </CreditAction>
            )}
          </Show>
          <Show when={localReceipt() || accountReceipt()}>
            <details class="model-providers__reset-receipt">
              <summary>
                {t(
                  localReceipt()
                    ? "modelProviders.resetCredits.receipt"
                    : "modelProviders.resetCredits.accountReceipt",
                )}
                <Show when={props.column}>
                  {(column) => <span class="settings-control__sr-label"> ({column().name})</span>}
                </Show>
              </summary>
              <Show when={localReceipt()}>
                {(phase) => <div>{t(`modelProviders.resetCredits.${phase()}`)}</div>}
              </Show>
              <Show when={accountReceipt()}>
                {(last) => (
                  <div>
                    <Show when={localReceipt()}>
                      {t("modelProviders.resetCredits.accountReceipt")}:{" "}
                    </Show>
                    {t(`modelProviders.resetCredits.${last().outcome}`)}
                  </div>
                )}
              </Show>
            </details>
          </Show>
        </div>
      </Show>
      <div
        class={[
          "model-providers__reset-status",
          { "sr-only": !attention() && !accountPending() && !needsRefresh() },
        ]}
        role="status"
      >
        <Show when={props.column && (attention() || accountPending() || needsRefresh())}>
          <strong>{props.column?.name}</strong>
        </Show>
        <Show when={attention()}>
          {(phase) => <div>{t(`modelProviders.resetCredits.${phase()}`)}</div>}
        </Show>
        <Show when={accountPending()}>
          <div>{t("modelProviders.resetCredits.accountPending")}</div>
        </Show>
        <Show when={journal()?.journalUnavailable}>
          <div>{t("modelProviders.resetCredits.journalUnavailable")}</div>
        </Show>
        <Show when={needsRefresh()}>
          <button type="button" class="btn btn--sm" onClick={() => props.refresh()}>
            {t("modelProviders.resetCredits.refresh")}
          </button>
        </Show>
      </div>
    </>
  );
}

function CreditAction(props: {
  selection: Selection;
  name?: string;
  account: Account;
  children: JSX.Element;
  refresh: () => void;
  ready: () => boolean;
  observed: () => ResetAttempt | undefined;
  onSpend: (prepared: Prepared, observed: ResetAttempt | undefined, creditId: string) => void;
  status: () => HTMLElement;
}) {
  const dialog = observeState({
    open: false,
    index: 0,
    seconds: 0,
    error: false,
    expired: false,
    ticket: undefined as Prepared | undefined,
  });
  const [acknowledged, acknowledge] = createSignal(false);
  let trigger!: HTMLButtonElement;
  let modal!: OpenClawModalDialog;
  let cancel!: HTMLButtonElement;
  let observed: ResetAttempt | undefined;
  let opening = 0;
  let deadline = 0;
  let expires = 0;
  const expiry = createTimeout(() => {
    dialog.state.expired = true;
    dialog.state.ticket = undefined;
    dialog.state.seconds = 0;
  });
  const dismiss = () => {
    ++opening;
    expiry.cancel();
    dialog.state.open = false;
    dialog.state.ticket = undefined;
    dialog.state.seconds = 0;
  };
  // Time in a background tab is not time spent reviewing this confirmation.
  onSettled(() =>
    listen(document, "visibilitychange", () => {
      if (document.hidden) {
        dismiss();
      }
    }),
  );
  createInterval(
    () => {
      dialog.state.seconds = Math.max(0, Math.ceil((deadline - performance.now()) / 1000));
    },
    () => (dialog.read().open && dialog.read().seconds > 0 ? 250 : undefined),
  );
  const prepare = async (index: number) => {
    const offer = props.selection.choices[index];
    if (!offer || !trigger.isConnected || document.hidden || !props.ready()) {
      return;
    }
    const id = ++opening;
    const requestedAt = performance.now();
    expiry.cancel();
    dialog.state.ticket = undefined;
    dialog.state.seconds = 0;
    dialog.state.index = index;
    const { creditId } = offer;
    const { accountBinding, afterReset } = props.selection;
    const idempotencyKey = props.selection.idempotencyKey ?? generateUUID();
    observed = props.observed();
    dialog.state.open = true;
    dialog.state.error = false;
    dialog.state.expired = false;
    try {
      const prepared = await props.account.client.request<Prepared>(
        "codex.prepareResetCredit",
        {
          agentId: props.account.agentId,
          profileId: props.account.profileId,
          accountBinding,
          creditId,
          idempotencyKey,
          ...(afterReset && { afterReset }),
        },
        { timeoutMs: CODEX_ACCOUNT_REQUEST_TIMEOUT_MS },
      );
      if (opening !== id || !trigger.isConnected) {
        return;
      }
      if (
        !uuid.test(prepared.confirmationId) ||
        !uuid.test(prepared.idempotencyKey) ||
        !Number.isFinite(prepared.waitMs) ||
        prepared.waitMs < 5000 ||
        !Number.isFinite(prepared.expiresInMs) ||
        prepared.expiresInMs <= prepared.waitMs ||
        prepared.idempotencyKey !== idempotencyKey
      ) {
        throw new Error("Invalid reset confirmation");
      }
      const delay = prepared.waitMs;
      expires = requestedAt + prepared.expiresInMs;
      deadline = performance.now() + delay;
      if (deadline >= expires) {
        dialog.state.expired = true;
        return;
      }
      expiry.schedule(expires - performance.now());
      dialog.state.seconds = Math.ceil(delay / 1000);
      dialog.state.ticket = prepared;
    } catch {
      if (opening === id && trigger.isConnected) {
        dialog.state.error = true;
        props.refresh();
      }
    }
  };
  const submit = () => {
    const prepared = dialog.state.ticket;
    if (
      !dialog.state.open ||
      !trigger.isConnected ||
      !props.ready() ||
      observed !== props.observed() ||
      !prepared ||
      dialog.state.seconds > 0 ||
      deadline > performance.now() ||
      performance.now() >= expires ||
      document.hidden
    ) {
      return;
    }
    modal.setReturnFocusTarget(props.status());
    dismiss();
    props.onSpend(prepared, observed, props.selection.choices[dialog.state.index]!.creditId);
  };
  const dialogTitle = () =>
    t(
      props.selection.action === "retry"
        ? "modelProviders.resetCredits.retryTitle"
        : "modelProviders.resetCredits.title",
    );
  const warning = () =>
    props.selection.unresolved
      ? t("modelProviders.resetCredits.differentWarning")
      : t(
          props.selection.action === "retry"
            ? "modelProviders.resetCredits.retryWarning"
            : "modelProviders.resetCredits.warning",
        );
  // Codex orders offers by earliest expiry. IDs identify the charge, never its label.
  const options = createMemo(() => {
    const offers = props.selection.choices;
    const titles = offers.map(({ title, creditId }) =>
      title && !title.includes(creditId) && title.length <= 64 && !/[\p{C}]|\S{32}/u.test(title)
        ? title
        : undefined,
    );
    return offers.map((offer, index) => {
      const title = titles[index];
      const label =
        title && titles.indexOf(title) === titles.lastIndexOf(title)
          ? title
          : offers.length > 1
            ? t("modelProviders.resetCredits.ordinal", {
                number: formatNumber(index + 1),
                count: formatNumber(offers.length),
              })
            : undefined;
      return { title, label: [label, creditExpiry(offer.expiresAt)].filter(Boolean).join(" · ") };
    });
  });
  const accountScope = () => {
    // A saved profile name alone cannot identify the member charged by Codex.
    const id = props.selection.accountEmail || props.selection.memberId;
    const name = props.name;
    const account =
      name && name !== id && !name.endsWith(` · ${id}`) ? `${name} · ${id}` : name || id;
    return t("modelProviders.resetCredits.accountScope", {
      account,
      workspace: props.selection.workspaceId,
    });
  };
  const canChoose = () =>
    options().some(
      (option, index) =>
        option.title !== options()[0]?.title ||
        props.selection.choices[index]?.expiresAt !== props.selection.choices[0]?.expiresAt,
    );
  return (
    <>
      <Show when={props.selection.unresolved}>
        <label>
          <input
            type="checkbox"
            checked={acknowledged()}
            disabled={!props.ready()}
            onChange={(event) => acknowledge(event.currentTarget.checked)}
          />{" "}
          {t("modelProviders.resetCredits.acknowledge")}
        </label>
      </Show>
      <Show when={!props.selection.unresolved || acknowledged()}>
        <button
          ref={(node) => {
            trigger = node;
          }}
          type="button"
          class="btn btn--sm"
          disabled={!props.ready()}
          data-reset-credit-action
          onClick={() => {
            if (!dialog.state.open) {
              void prepare(0);
            }
          }}
        >
          {t(
            props.selection.action === "retry"
              ? "modelProviders.resetCredits.retry"
              : "modelProviders.resetCredits.use",
          )}
          <Show when={props.name}>
            {(name) => <span class="settings-control__sr-label"> ({name()})</span>}
          </Show>
        </button>
      </Show>
      <Show when={dialog.read().open}>
        <ModalDialog
          ref={(node) => {
            modal = node;
            node.setReturnFocusTarget(trigger);
          }}
          label={dialogTitle()}
          description={`${accountScope()}. ${warning()}`}
          initialFocus={() => cancel}
          onModal-cancel={dismiss}
        >
          <div class="oc-dialog confirm-dialog model-providers__reset-dialog">
            <DialogHeader title={dialogTitle()} description={<p>{accountScope()}</p>} />
            <div class="oc-dialog__body">
              <div>
                <p>{warning()}</p>
                {props.children}
              </div>
              <details class="model-providers__credit-choice">
                <summary>
                  {t(
                    canChoose()
                      ? "modelProviders.resetCredits.changeCredit"
                      : "modelProviders.resetCredits.creditDetails",
                  )}
                </summary>
                <Show when={canChoose()} fallback={<p>{options()[dialog.read().index]!.label}</p>}>
                  <select
                    aria-label={t("modelProviders.resetCredits.chooseCredit")}
                    value={String(dialog.read().index)}
                    disabled={!props.ready()}
                    onChange={(e) => {
                      if (dialog.state.open) {
                        void prepare(e.currentTarget.selectedIndex);
                      }
                    }}
                  >
                    <For each={options()}>
                      {(option, index) => <option value={String(index())}>{option.label}</option>}
                    </For>
                  </select>
                </Show>
                <Show when={props.selection.accountEmail}>
                  <p>
                    {t("modelProviders.resetCredits.memberId")}: {props.selection.memberId}
                  </p>
                </Show>
              </details>
              <div
                class={[{ "sr-only": !dialog.read().expired && !dialog.read().error }]}
                aria-live="polite"
              >
                <Show
                  when={dialog.read().error || dialog.read().expired}
                  fallback={
                    <Show
                      when={dialog.read().ticket}
                      fallback={t("modelProviders.resetCredits.preparing")}
                    >
                      <Show when={dialog.read().seconds === 0}>
                        {t("modelProviders.resetCredits.ready")}
                      </Show>
                    </Show>
                  }
                >
                  {t(
                    dialog.read().expired
                      ? "modelProviders.resetCredits.expired"
                      : "modelProviders.resetCredits.prepareError",
                  )}
                </Show>
              </div>
            </div>
            <openclaw-modal-actions class="oc-dialog__footer">
              <button
                ref={(node) => {
                  cancel = node;
                }}
                type="button"
                class="btn"
                autofocus
                onClick={dismiss}
              >
                {t("common.cancel")}
              </button>
              <button
                type="button"
                class="btn danger"
                disabled={
                  !props.ready() ||
                  !dialog.read().ticket ||
                  dialog.read().seconds > 0 ||
                  observed !== props.observed()
                }
                onKeyDown={(event) => {
                  if (
                    event.key === "Enter" &&
                    (event.repeat ||
                      event.currentTarget !== event.currentTarget.ownerDocument.activeElement)
                  ) {
                    event.preventDefault();
                  }
                }}
                onClick={submit}
              >
                {!dialog.read().ticket && !dialog.read().expired && !dialog.read().error
                  ? t("modelProviders.resetCredits.preparing")
                  : dialog.read().seconds > 0
                    ? t("modelProviders.resetCredits.countdown", {
                        seconds: String(dialog.read().seconds),
                      })
                    : t(
                        props.selection.action === "retry"
                          ? "modelProviders.resetCredits.confirmRetry"
                          : "modelProviders.resetCredits.spend",
                      )}
              </button>
            </openclaw-modal-actions>
          </div>
        </ModalDialog>
      </Show>
    </>
  );
}

function creditExpiry(expiresAt?: number | null) {
  return expiresAt === null
    ? t("modelProviders.resetCredits.noExpiry")
    : expiresAt === undefined
      ? t("modelProviders.resetCredits.unknownExpiry")
      : t("modelProviders.resetCredits.expiresOn", {
          date: formatDateTimeMs(expiresAt * 1000, { dateStyle: "medium", timeStyle: "short" }),
        });
}
