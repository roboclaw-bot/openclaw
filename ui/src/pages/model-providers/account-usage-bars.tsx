import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, For, Loading, omit, Show } from "solid-js";
import {
  remainingPercent,
  remainingTone,
  resetText,
} from "../../components/solid/provider-usage.tsx";
import { moveArrayEntry } from "../../lib/array-order.ts";
import { formatNumber } from "../../lib/reactive/format.ts";
import { t } from "../../lib/reactive/i18n.ts";
import { createPointerDrag } from "../../lib/reactive/pointer-drag.ts";
import { accountCreditBalance, type AccountUsageRead } from "./account-usage.tsx";
import { neighborOffset, reorderByArrow } from "./profile-reorder.ts";

function UsageTrack(props: { label?: string; children: JSX.Element }) {
  return (
    <div
      class="model-providers__usage-window"
      role={props.label === undefined ? undefined : "group"}
      aria-label={props.label}
    >
      <span class={props.label === undefined ? undefined : "model-providers__usage-label"}>
        {props.label}
      </span>
      <div class="model-providers__usage-track">{props.children}</div>
    </div>
  );
}

/** Equal slots compare accounts, not token capacity. Only windows with the same label share a track. */
export function AccountUsageBars(props: {
  readings: (AccountUsageRead & { name: () => string; status: () => JSX.Element })[];
  expandedAccount?: string;
  onToggleAccount: (id: string) => void;
  canReorder: boolean;
  onReorder: (ids: string[]) => void;
}) {
  const ids = createMemo(() => props.readings.map((read) => read.account().profileId));
  const tracks = createMemo(() => {
    const accounts = props.readings.map((read) => ({
      id: read.account().profileId,
      name: read.name(),
      value: read.result(),
    }));
    const labels = new Set(
      accounts.flatMap(
        ({ value }) =>
          value.snapshot?.windows.filter((w) => !w.groupLabel).map((w) => w.label) ?? [],
      ),
    );
    return Array.from(labels, (label) => ({
      label,
      segments: accounts.map(({ id, name, value }) => {
        const window = value.snapshot?.windows.find((w) => !w.groupLabel && w.label === label);
        const percent = window && remainingPercent(window);
        const reset = window && resetText(window);
        const quota =
          percent === undefined
            ? (value.error ??
              value.snapshot?.error ??
              t(value.loading ? "common.loading" : "modelProviders.limits.notReported"))
            : t("usage.providerUsage.remaining", { percent: String(percent) });
        return {
          id,
          percent,
          tone: window && remainingTone(window),
          detail: [
            name,
            label,
            quota,
            reset?.date && t("usage.providerUsage.resets", { date: reset.date }),
          ]
            .filter(Boolean)
            .join(" · "),
        };
      }),
    }));
  });
  const drag = createPointerDrag({ cancelOnEscape: true });
  const [preview, setPreview] = createSignal<{
    source: number;
    target: number;
    dx: number;
    pitch: number;
  }>();
  let suppressPointerClick = false;
  const translation = (index: number) => {
    const p = preview();
    if (!p) {
      return undefined;
    }
    if (index === p.source) {
      return `${p.dx}px`;
    }
    return `${neighborOffset(index, p.source, p.target, p.pitch)}px`;
  };
  const [selected, select] = createSignal<{ id: string; label: string }>();
  const move = (source: string, target: string) => {
    const current = ids();
    if (
      !props.canReorder ||
      source === target ||
      !current.includes(source) ||
      !current.includes(target)
    ) {
      return;
    }
    props.onReorder(moveArrayEntry(current, source, target));
  };
  let chart!: HTMLElement;
  const startDrag = (event: PointerEvent, source: number) => {
    const cell = event.currentTarget;
    suppressPointerClick = false;
    if (
      !props.canReorder ||
      !event.isPrimary ||
      event.button !== 0 ||
      !(cell instanceof HTMLElement)
    ) {
      return;
    }
    const track = cell.parentElement;
    const first = track?.children[0];
    const second = track?.children[1];
    if (!track || !first || !second) {
      return;
    }
    // Equal-width columns: measure the original slot pitch, never the moving cells.
    const pitch = second.getBoundingClientRect().x - first.getBoundingClientRect().x;
    const initialIds = ids();
    let dragged = false;
    let target = source;
    const update = (p: PointerEvent) => {
      const dx = p.clientX - event.clientX;
      if (!dragged && Math.abs(dx) < 4) {
        return;
      }
      dragged = true;
      const bounds = track.getBoundingClientRect();
      const vertical = chart.getBoundingClientRect();
      const inside =
        p.clientX >= bounds.left &&
        p.clientX <= bounds.right &&
        p.clientY >= vertical.top &&
        p.clientY <= vertical.bottom;
      target = inside
        ? Math.max(0, Math.min(initialIds.length - 1, source + Math.round(dx / pitch)))
        : source;
      setPreview({ source, target, pitch, dx });
    };
    const cleanup = () => {
      suppressPointerClick = dragged;
      setPreview(undefined);
    };
    drag.start(event, cell, {
      move: update,
      cancel: cleanup,
      end: (p) => {
        update(p);
        cleanup();
        if (target !== source) {
          move(initialIds[source]!, initialIds[target]!);
        }
      },
    });
  };
  function ColumnButton(
    cell: JSX.ButtonHTMLAttributes<HTMLButtonElement> & {
      index: number;
      activate: () => void;
    },
  ) {
    const attributes = omit(cell, "index", "activate", "title", "children");
    return (
      <button
        {...attributes}
        type="button"
        title={preview() ? undefined : cell.title}
        data-movable={props.canReorder || undefined}
        data-grabbed={preview()?.source === cell.index || undefined}
        style={{ translate: translation(cell.index) }}
        aria-keyshortcuts={props.canReorder ? "ArrowLeft ArrowRight" : undefined}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            select(undefined);
          } else if (props.canReorder) {
            const source = ids()[cell.index]!;
            reorderByArrow(e, ids(), cell.index, "horizontal", (target) => move(source, target));
          }
        }}
        onPointerDown={(e) => startDrag(e, cell.index)}
        onClick={(e) => {
          if (!e.detail || !suppressPointerClick) {
            cell.activate();
          }
        }}
      >
        {cell.children}
      </button>
    );
  }
  function CreditTrack(kind: { reset?: boolean }) {
    return (
      <UsageTrack
        label={
          kind.reset ? t("modelProviders.limits.resetCredits") : t("modelProviders.limits.credits")
        }
      >
        <For each={props.readings}>
          {(read, index) => {
            const credit = createMemo(() => {
              const amount = kind.reset
                ? read.result().resetCredits?.availableCount
                : accountCreditBalance(read.result().snapshot)?.amount;
              return amount === undefined
                ? undefined
                : formatNumber(amount, { maximumFractionDigits: 0 });
            });
            const expanded = () => props.expandedAccount === read.account().profileId;
            const canReview = () => {
              if (!kind.reset || !read.canConsume()) {
                return false;
              }
              const { resetCredits, operation, stale } = read.result();
              // A bound reading can disclose its offers or pending reset. Details own consent.
              return (
                operation &&
                !stale &&
                resetCredits &&
                !resetCredits.readOnly &&
                !resetCredits.journalUnavailable &&
                (resetCredits.pending ||
                  ((resetCredits.availableCount ?? 0) > 0 &&
                    (resetCredits.creditId || resetCredits.offers?.length)))
              );
            };
            return (
              <span
                class="model-providers__credit"
                data-grabbed={preview()?.source === index() || undefined}
                style={{ translate: translation(index()) }}
              >
                <span class="settings-control__sr-label">
                  {read.name()}:{" "}
                  {credit() ??
                    t(
                      read.result().loading
                        ? "common.loading"
                        : "modelProviders.limits.notReported",
                    )}
                </span>
                <span aria-hidden="true">{credit() ?? "—"}</span>
                <Show when={canReview()}>
                  <button
                    type="button"
                    class="btn btn--sm"
                    aria-expanded={expanded() ? "true" : "false"}
                    onClick={() => props.onToggleAccount(read.account().profileId)}
                  >
                    {t(
                      expanded()
                        ? "modelProviders.resetCredits.hideDetails"
                        : read.result().resetCredits?.pending
                          ? "modelProviders.resetCredits.reviewPending"
                          : "modelProviders.resetCredits.review",
                    )}
                    <span class="settings-control__sr-label"> ({read.name()})</span>
                  </button>
                </Show>
              </span>
            );
          }}
        </For>
      </UsageTrack>
    );
  }
  const selectedDetail = () =>
    tracks()
      .find((track) => track.label === selected()?.label)
      ?.segments.find((segment) => segment.id === selected()?.id)?.detail;
  return (
    <section
      ref={(el) => (chart = el)}
      class="model-providers__usage-bars"
      data-sorting={preview() ? true : undefined}
      aria-label={t("modelProviders.limits.subscriptionLimits")}
    >
      <Loading fallback={<small>{t("common.loading")}</small>}>
        <UsageTrack>
          <For each={props.readings}>
            {(read, index) => {
              const id = () => read.account().profileId;
              const plan = () => read.result().snapshot?.plan?.trim();
              return (
                <ColumnButton
                  index={index()}
                  activate={() => props.onToggleAccount(id())}
                  aria-expanded={props.expandedAccount === id() ? "true" : "false"}
                  class="model-providers__segment-name"
                  aria-description={plan() || undefined}
                  title={[read.name(), plan()].filter(Boolean).join(" · ")}
                >
                  <span class="settings-control__sr-label">
                    {t("modelProviders.limits.detailsFor", {
                      account: read.name(),
                    })}
                  </span>
                  <span class="model-providers__account-name" aria-hidden="true">
                    {read.name()}
                  </span>
                  {read.status()}
                </ColumnButton>
              );
            }}
          </For>
        </UsageTrack>
        <For each={tracks()} keyed={(track) => track.label}>
          {(track) => (
            <UsageTrack label={track().label}>
              <For each={track().segments} keyed={(s) => s.id}>
                {(segment, index) => {
                  const id = () => segment().id;
                  const pressed = () =>
                    selected()?.id === id() && selected()?.label === track().label;
                  return (
                    <ColumnButton
                      index={index()}
                      class="model-providers__usage-segment"
                      data-account-segment={id()}
                      data-known={segment().percent !== undefined}
                      data-tone={segment().tone}
                      aria-label={segment().detail}
                      title={segment().detail}
                      aria-pressed={pressed() ? "true" : "false"}
                      activate={() =>
                        select(pressed() ? undefined : { id: id(), label: track().label })
                      }
                    >
                      <span
                        class="model-providers__segment-fill"
                        aria-hidden="true"
                        style={{ width: (segment().percent ?? 0) + "%" }}
                      />
                      <strong>
                        {segment().percent === undefined ? "—" : segment().percent + "%"}
                      </strong>
                    </ColumnButton>
                  );
                }}
              </For>
            </UsageTrack>
          )}
        </For>
        <CreditTrack />
        <Show
          when={props.readings.some((read) => {
            const credits = read.result().resetCredits;
            return credits?.availableCount !== undefined || credits?.pending;
          })}
        >
          <CreditTrack reset />
        </Show>
        <For each={props.readings}>
          {(read) => {
            const outcome = () => {
              const { loading, error, snapshot, stale } = read.result();
              const failure = error ?? snapshot?.error;
              const status =
                failure === undefined
                  ? loading
                    ? t("common.loading")
                    : undefined
                  : failure
                    ? t("modelProviders.limits.readFailed", { error: failure })
                    : t("usage.providerUsage.unavailable");
              return [stale && t("modelProviders.resetCredits.cachedQuota"), status]
                .filter(Boolean)
                .join(" · ");
            };
            return (
              <Show when={outcome()}>
                {(message) => (
                  <small role="status">
                    {read.name()}: {message()}
                  </small>
                )}
              </Show>
            );
          }}
        </For>
        <Show when={selectedDetail()}>{(detail) => <small role="status">{detail()}</small>}</Show>
      </Loading>
    </section>
  );
}
