import { createMemo, createSignal, For, onSettled, Show } from "solid-js";
import type { GatewayBrowserClient } from "../../api/gateway.ts";
import { ModalDialog, type OpenClawModalDialog } from "../../components/modal-dialog.tsx";
import { DialogHeader } from "../../components/solid/dialog-header.tsx";
import { formatDateTimeMs, formatTimeMs } from "../../lib/reactive/format.ts";
import { t } from "../../lib/reactive/i18n.ts";
import { listen } from "../../lib/reactive/listener.ts";
import { observeState } from "../../lib/reactive/observe-state.ts";
import { projectOwner } from "../../lib/reactive/projection.ts";
import { createInterval, createTimeout } from "../../lib/reactive/timers.ts";
import { generateUUID } from "../../lib/uuid.ts";
import {
  CODEX_ACCOUNT_REQUEST_TIMEOUT_MS,
  hasResetIdentity,
  type ResetAttempt,
  type ResetCreditBalance,
  type ResetIntent,
  type ResetOperation,
} from "./reset-credit-operation.ts";

type Account = {
  client: GatewayBrowserClient;
  agentId: string;
  profileId: string;
};
type Summary = {
  resetCredits?: ResetCreditBalance;
  operation?: ResetOperation;
  observed?: ResetAttempt;
  error?: string;
  nextReset?: { at: number; label: string };
};
type Selection = {
  accountBinding: string;
  accountLabel: string;
  accountEmail?: string;
  memberId: string;
  workspaceId: string;
  creditId: string;
  expiresAt?: number | null;
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

export function AccountResetCredits(props: {
  account: Account;
  summary: Summary;
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
      attempt() || journal()?.pending || journal()?.lastReset || journal()?.journalUnavailable,
    );
  // A choice is local to the verified subscription, never an operation or reservation.
  const [choice, choose] = createSignal<{ binding: string; id: string }>();
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
    const candidates: { creditId: string; expiresAt?: number | null; title?: string }[] =
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
          creditId: retry.creditId,
          expiresAt: offer?.expiresAt,
          afterReset: own(retry) ? local?.afterReset : undefined,
          idempotencyKey: retry.idempotencyKey,
          action: "retry",
        };
      }
      const selected = choice();
      const offer =
        (selected?.binding === accountBinding
          ? offers().find((o) => o.creditId === selected.id)
          : undefined) ?? offers()[0];
      if (!offer || (credits.availableCount ?? 0) <= 0) {
        return undefined;
      }
      const last = credits.lastReset;
      return {
        ...identity,
        creditId: offer.creditId,
        expiresAt: offer.expiresAt,
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
        a?.expiresAt === b?.expiresAt &&
        a?.creditId === b?.creditId &&
        a?.idempotencyKey === b?.idempotencyKey &&
        a?.afterReset === b?.afterReset &&
        a?.action === b?.action &&
        a?.unresolved === b?.unresolved,
    },
  );
  let status!: HTMLDivElement;
  return (
    <>
      <Show when={(balance()?.availableCount !== undefined || target()) && balance()}>
        {(credits) => (
          <div class="model-providers__reset-credits">
            <Show when={credits().availableCount !== undefined}>
              <strong>
                {t("modelProviders.resetCredits.balance", {
                  count: String(credits().availableCount),
                })}
              </strong>
            </Show>
            <Show when={offers().length > 1 && target() && target()?.action !== "retry"}>
              <label class="model-providers__credit-choice">
                <span>{t("modelProviders.resetCredits.chooseCredit")}</span>
                <select
                  value={target()?.creditId}
                  disabled={!fresh() || attempt()?.phase === "pending"}
                  onChange={(e) => {
                    const selected = target();
                    if (selected) {
                      choose({ binding: selected.accountBinding, id: e.currentTarget.value });
                    }
                  }}
                >
                  <For each={offers()} keyed={(o) => o.creditId}>
                    {(offer) => (
                      <option value={offer().creditId}>
                        {offer().creditId} — {creditExpiry(offer().expiresAt)}
                      </option>
                    )}
                  </For>
                </select>
              </label>
            </Show>
            <Show
              when={target()}
              keyed
              fallback={
                <Show when={!activity() && (credits().availableCount ?? 0) > 0}>
                  <span>
                    {t(
                      credits().readOnly || credits().creditId || credits().offers?.length
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
                  account={props.account}
                  nextReset={props.summary.nextReset}
                  refresh={props.refresh}
                  ready={() =>
                    props.canConsume() &&
                    target() === selected &&
                    fresh() &&
                    attempt()?.phase !== "pending"
                  }
                  observed={() => owner()?.current}
                  onSpend={(prepared, observed) =>
                    void owner()?.spend(
                      props.account.client,
                      props.account,
                      {
                        creditId: selected.creditId,
                        idempotencyKey: prepared.idempotencyKey,
                        afterReset: selected.afterReset,
                      },
                      prepared.confirmationId,
                      observed,
                      selected.action === "retry",
                    )
                  }
                  status={() => status}
                />
              )}
            </Show>
          </div>
        )}
      </Show>
      <div
        ref={(node) => {
          status = node;
        }}
        class={[{ "sr-only": !activity() }]}
        role="status"
        tabindex="-1"
      >
        <Show when={attempt()}>
          {(local) => (
            <div>
              {t("modelProviders.resetCredits.yourRequest", { credit: local().creditId })}{" "}
              {t(`modelProviders.resetCredits.${local().phase}`)}
            </div>
          )}
        </Show>
        <Show when={journal()?.lastReset}>
          {(last) => (
            <Show when={!own(last()) || attempt()?.phase !== last().outcome}>
              <div>
                {t("modelProviders.resetCredits.lastAccountReset", { credit: last().creditId })}{" "}
                {t(`modelProviders.resetCredits.${last().outcome}`)}
              </div>
            </Show>
          )}
        </Show>
        <Show when={journal()?.pending}>
          {(pending) => (
            <Show
              when={
                !own(pending()) ||
                (attempt()?.phase !== "pending" && attempt()?.phase !== "uncertain")
              }
            >
              <div>
                {t("modelProviders.resetCredits.accountPending", { credit: pending().creditId })}
              </div>
            </Show>
          )}
        </Show>
        <Show when={journal()?.journalUnavailable}>
          <div>{t("modelProviders.resetCredits.journalUnavailable")}</div>
        </Show>
        <Show
          when={
            attempt()?.phase === "uncertain" ||
            journal()?.pending ||
            journal()?.journalUnavailable ||
            (attempt() && !fresh() && attempt()?.phase !== "pending")
          }
        >
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
  account: Account;
  nextReset?: { at: number; label: string };
  refresh: () => void;
  ready: () => boolean;
  observed: () => ResetAttempt | undefined;
  onSpend: (prepared: Prepared, observed: ResetAttempt | undefined) => void;
  status: () => HTMLElement;
}) {
  const dialog = observeState({
    open: false,
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
  const open = async () => {
    if (!trigger.isConnected || document.hidden || !props.ready() || dialog.state.open) {
      return;
    }
    const id = ++opening;
    const requestedAt = performance.now();
    const { creditId, accountBinding, afterReset } = props.selection;
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
    props.onSpend(prepared, observed);
  };
  const title = () =>
    t(
      props.selection.action === "retry"
        ? "modelProviders.resetCredits.retryTitle"
        : props.selection.action === "newSpend"
          ? "modelProviders.resetCredits.newTitle"
          : "modelProviders.resetCredits.title",
    );
  const warning = () =>
    props.selection.unresolved
      ? t("modelProviders.resetCredits.differentWarning", {
          credit: props.selection.unresolved.creditId,
        })
      : t(
          props.selection.action === "retry"
            ? "modelProviders.resetCredits.retryWarning"
            : "modelProviders.resetCredits.warning",
        );
  const accountName = () => props.selection.accountEmail;
  return (
    <>
      <Show when={props.selection.unresolved}>
        {(previous) => (
          <label>
            <input
              type="checkbox"
              checked={acknowledged()}
              disabled={!props.ready()}
              onChange={(event) => acknowledge(event.currentTarget.checked)}
            />{" "}
            {t("modelProviders.resetCredits.acknowledge", { credit: previous().creditId })}
          </label>
        )}
      </Show>
      <Show when={!props.selection.unresolved || acknowledged()}>
        <button
          ref={(node) => {
            trigger = node;
          }}
          type="button"
          class="btn btn--sm"
          disabled={!props.ready()}
          onClick={() => void open()}
        >
          {t(`modelProviders.resetCredits.${props.selection.action}`)}
        </button>
      </Show>
      <Show when={dialog.read().open}>
        <ModalDialog
          ref={(node) => {
            modal = node;
            node.setReturnFocusTarget(trigger);
          }}
          label={title()}
          description={warning()}
          initialFocus={() => cancel}
          onModal-cancel={dismiss}
        >
          <div class="oc-dialog confirm-dialog">
            <DialogHeader title={title()} description={<p>{warning()}</p>} />
            <div class="oc-dialog__body">
              <dl class="settings-kv">
                <dt>{t("modelProviders.resetCredits.account")}</dt>
                <dd>
                  <Show when={accountName()} fallback={props.selection.memberId}>
                    {(email) => (
                      <details>
                        <summary>{email()}</summary>
                        {t("modelProviders.resetCredits.memberId")}: {props.selection.memberId}
                      </details>
                    )}
                  </Show>
                </dd>
                <Show when={props.selection.workspaceId}>
                  {(value) => (
                    <>
                      <dt>{t("modelProviders.resetCredits.workspaceId")}</dt>
                      <dd>{value()}</dd>
                    </>
                  )}
                </Show>
                <dt>{t("modelProviders.resetCredits.creditId")}</dt>
                <dd>{props.selection.creditId}</dd>
                <dt>{t("modelProviders.resetCredits.expiry")}</dt>
                <dd>{creditExpiry(props.selection.expiresAt)}</dd>
              </dl>
              <WindowResetHint next={props.nextReset} />
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
      : formatDateTimeMs(expiresAt * 1000, { dateStyle: "medium", timeStyle: "short" });
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
