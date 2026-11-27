import { GatewayProtocolRequestTimeoutError } from "@openclaw/gateway-client/browser";
import { createSignal } from "solid-js";
import { afterEach, expect, it, vi } from "vitest";
import { retainGatewayResponsePayload } from "../../../../packages/gateway-client/src/protocol-request.js";
import type { UsageSummary } from "../../../../src/infra/provider-usage.types.js";
import { createDeferredCore } from "../../../../src/shared/deferred.js";
import { GatewayBrowserClient, GatewayRequestError } from "../../api/gateway.ts";
import { registerSettingsEnglish } from "../../i18n/locales/en-settings.ts";
import * as toasts from "../../lib/toast.ts";
import * as browserStorage from "../../local-storage.ts";
import {
  createGatewayRequestMock,
  createTestGatewayClient,
} from "../../test-helpers/gateway-client.ts";
import { expectContent } from "../../test-helpers/model-providers.ts";
import { flush, waitForSolid } from "../../test-helpers/solid-settle.ts";
import { createStorageMock } from "../../test-helpers/storage.ts";
import type { ResetCreditBalance } from "./reset-credit-operation.ts";
import {
  advanceClock as tick,
  confirmReset as send,
  mountAccountUsage as mount,
  openReset as open,
  refreshAccountUsage as refreshView,
  useResetCredit as actionName,
} from "./test-support/account-usage.tsx";

registerSettingsEnglish();
afterEach(() => vi.useRealTimers());

function accountSnapshot(fields: Partial<UsageSummary["providers"][number]> = {}): UsageSummary {
  return {
    updatedAt: 1,
    providers: [{ provider: "openai", displayName: "OpenAI", windows: [], ...fields }],
  };
}
const snapshot = (usedPercent = 25, amount = 12) =>
  accountSnapshot({
    plan: "Pro",
    windows: [{ label: "5h", usedPercent }],
    billing: [{ type: "balance", amount, unit: "credits" }],
  });

it("loads automatically, renders remaining quota and balance, and re-reads on a new revision", async () => {
  const raw = snapshot(25, 42219.4424345);
  let nextResult: UsageSummary | Promise<UsageSummary> = raw;
  const request = createGatewayRequestMock(async () => nextResult);
  const view = mount(request);
  await waitForSolid(() => expect(view.container.textContent).toContain("42,219 credits"));
  expect(raw.providers[0]?.billing?.[0]).toMatchObject({ amount: 42219.4424345 });
  expect(view.container.textContent).toContain("Pro");
  expect(view.container.querySelector('[role="meter"]')?.getAttribute("aria-valuenow")).toBe("75");
  // A rebuilt scope with the same fields is the same account read.
  view.setScope({ ...view.scope() });
  flush();
  expect(request).toHaveBeenCalledTimes(1);
  const window = view.container.querySelector(".provider-usage__window");
  const refresh = createDeferredCore<UsageSummary>();
  nextResult = refresh.promise;
  view.setScope({ ...view.scope(), revision: 1 });
  await waitForSolid(() => expect(request.mock.calls.length).toBe(2));
  expect(request.mock.lastCall?.[1]).toEqual({ agentId: "main", profileId: "openai:account" });
  expect(view.container.querySelector(".provider-usage__window")).toBe(window);
  expect(view.container.textContent).toContain("42,219 credits");
  refresh.resolve(snapshot(90, 14));
  await waitForSolid(() => expect(view.container.textContent).toContain("14 credits"));
  expect(view.container.querySelector(".provider-usage__window")).toBe(window);
  expect(view.container.querySelector('[role="meter"]')?.getAttribute("aria-valuenow")).toBe("10");

  const otherAccount = createDeferredCore<UsageSummary>();
  nextResult = otherAccount.promise;
  view.setScope({ ...view.scope(), agentId: "other" });
  await waitForSolid(() => expect(request.mock.calls.length).toBe(3));
  expect(view.container.textContent).not.toContain("14 credits");
  expect(view.container.querySelector(".provider-usage__window")).toBeNull();
  otherAccount.resolve(snapshot());
  await waitForSolid(() => expect(view.container.textContent).toContain("12 credits"));
});

it("drops a pending response when the selected agent changes and shows the current error", async () => {
  const stale = createDeferredCore();
  const request = createGatewayRequestMock(async (_method, params) => {
    if ((params as { agentId: string }).agentId === "main") {
      await stale.promise;
      return snapshot();
    }
    throw new Error("Account usage unavailable");
  });
  const view = mount(request);
  await waitForSolid(() => expect(request.mock.calls.length).toBe(1));
  view.setScope({ ...view.scope(), agentId: "other" });
  await waitForSolid(() =>
    expect(view.container.textContent).toContain("Account usage unavailable"),
  );
  expect(request.mock.calls[0]?.[2]?.signal?.aborted).toBe(true);
  stale.resolve();
  await stale.promise;
  flush();
  expect(view.container.textContent).toContain("Account usage unavailable");
  expect(view.container.textContent).not.toContain("12 credits");
});

it("shows the empty state when Codex returns a snapshot without quota data", async () => {
  const request = createGatewayRequestMock(() => accountSnapshot());
  const view = mount(request);
  await waitForSolid(() => expect(view.container.textContent).toContain("No live usage data"));
});

const usage = "codex.accountUsage";
const prepare = "codex.prepareResetCredit";
const consume = "codex.consumeResetCredit";
const retryName = "Retry the original reset";
const unknownOutcome = "Your reset is unconfirmed.";
function waitForContent(
  view: ReturnType<typeof mount>,
  includes: string[],
  excludes: string[] = [],
) {
  return waitForSolid(() => expectContent(view.container, includes, excludes));
}
function waitForStatus(view: ReturnType<typeof mount>, ...messages: string[]) {
  return waitForSolid(() => expectContent(view.getByRole("status"), messages));
}
const account = {
  accountBinding: "binding-A",
  accountLabel: "prepared@example.test · member-M · workspace-W",
  accountEmail: "prepared@example.test",
  memberId: "member-M",
  workspaceId: "workspace-W",
};
const keyA = "3ba3ba2c-eb3b-4537-a733-ab21e3b176c9";
const receipt = "8673fb72-3222-492e-8c1a-f45cb21fe2d9";
const confirmationId = "55a79082-376c-4b78-8851-876ca262133d";
const ticket = { confirmationId, expiresInMs: 120000, waitMs: 5000 };
const row = { agentId: "main", profileId: "openai:account" };
type Spend = {
  creditId: string;
  idempotencyKey: string;
  confirmationId?: string;
  afterReset?: string;
};
const offered = (
  creditId: string,
  extra: Partial<ResetCreditBalance> = {},
): ResetCreditBalance => ({ ...account, availableCount: 1, creditId, ...extra });
function prepared(idempotencyKey: string, id = confirmationId) {
  return { ...ticket, confirmationId: id, idempotencyKey };
}
const sentTimeout = (method: string) =>
  new GatewayProtocolRequestTimeoutError({ method, timeoutMs: 30_000, requestSent: true });
type UsageParams = { profileId: string; quotaOnly?: boolean };
function fixture(
  read?: (params: UsageParams) => Promise<UsageSummary & { resetCredits?: ResetCreditBalance }>,
) {
  vi.useFakeTimers({
    toFake: ["setInterval", "clearInterval", "setTimeout", "clearTimeout", "performance"],
  });
  const io = {
    balance: offered("A", { availableCount: 2 }),
    connected: true,
    quotas: snapshot(),
    prepare: async ({ idempotencyKey }: Spend) => prepared(idempotencyKey),
    spend: async (_intent: Spend): Promise<{ outcome: string }> => ({ outcome: "reset" }),
  };
  const request = createGatewayRequestMock(async (method, params, options) => {
    if (method === usage) {
      if (read) {
        return read(params as UsageParams);
      }
      return (params as UsageParams).quotaOnly
        ? io.quotas
        : { ...io.quotas, resetCredits: io.balance };
    }
    if (method === prepare) {
      return io.prepare(params as Spend);
    }
    if (method === consume) {
      if (!io.connected) {
        // Use the production browser transport offline: no socket, onSent, or network call.
        return new GatewayBrowserClient({ url: "ws://test.invalid" }).request(
          method,
          params,
          options,
        );
      }
      options?.onSent?.("request-id");
      return io.spend(params as Spend);
    }
    throw new Error("Unexpected RPC: " + method);
  });
  return {
    io,
    request,
    writes: () => request.mock.calls.filter(([m]) => m === consume).map(([, p]) => p as Spend),
    previews: () => request.mock.calls.filter(([m]) => m === prepare).map(([, p]) => p as Spend),
  };
}

it("opens a non-spending preparation; after its reply five full seconds enable only a deliberate confirm", async () => {
  const { io, request, previews, writes } = fixture();
  const view = mount(request);
  const deferred = createDeferredCore<Awaited<ReturnType<typeof io.prepare>>>();
  io.prepare = () => deferred.promise;
  const first = await open(view);
  expect(first.dialog.querySelector("input")).toBeNull();
  const target = `${account.accountEmail} · Workspace: ${account.workspaceId}`;
  expect(first.dialog.getAttribute("aria-description")).toContain(target);
  expect(view.getByText(target).closest("details")).toBeNull();
  const details = first.dialog.querySelector("details")!;
  expect(details.open).toBe(false);
  expect(details.querySelector("summary")?.textContent).toBe("Credit details");
  expectContent(details, [account.memberId, "Expiry unknown"]);
  expect(first.dialog.textContent).not.toContain(account.accountLabel);
  expect(document.activeElement).toBe(first.cancel);
  expect(previews()).toEqual([
    { ...row, accountBinding: "binding-A", creditId: "A", idempotencyKey: expect.any(String) },
  ]);
  await tick(7000);
  expect(first.button.disabled).toBe(true);
  deferred.resolve(prepared(previews()[0]!.idempotencyKey));
  await tick(0);
  expect(first.button.textContent).toMatch(/5/);
  await tick(4999);
  expect(first.button.disabled).toBe(true);
  await tick(1);
  expect(first.button.disabled).toBe(false);
  const held = new KeyboardEvent("keydown", {
    key: "Enter",
    repeat: true,
    bubbles: true,
    cancelable: true,
  });
  first.button.focus();
  first.button.dispatchEvent(held);
  expect(held.defaultPrevented).toBe(true);
  expect(writes()).toHaveLength(0);
  first.button.click();
  first.button.click();
  expect(writes()).toEqual([{ ...previews()[0], confirmationId }]);
  expect(
    request.mock.calls
      .filter(([m]) => m === prepare || m === consume)
      .map((call) => call[2]?.timeoutMs),
  ).toEqual([30_000, 30_000]);
  await waitForSolid(() =>
    expect(document.activeElement).toBe(
      view.container.querySelector(".model-providers__reset-credits"),
    ),
  );
});

it.each([
  "member",
  "credit",
  "profile",
  "agent",
  "connection",
  "last receipt",
  "pending key",
  "journal unavailable",
])("discards delayed confirmation when %s changes, without spending", async (change) => {
  const { io, request, writes, previews } = fixture();
  const view = mount(request);
  if (change === "pending key") {
    io.balance.pending = { creditId: "A", idempotencyKey: keyA };
  }
  const late = createDeferredCore<Awaited<ReturnType<typeof io.prepare>>>();
  io.prepare = () => late.promise;
  const first = await open(view, change === "pending key" ? retryName : actionName);
  io.balance = {
    ...io.balance,
    ...(change === "member" && { accountBinding: "binding-B", memberId: "member-B" }),
    ...(change === "credit" && { creditId: "B" }),
    ...(change === "journal unavailable" && { journalUnavailable: true }),
    ...(change === "last receipt" && {
      lastReset: { creditId: "earlier", idempotencyKey: receipt, outcome: "reset" as const },
    }),
    ...(change === "pending key" && { pending: { creditId: "A", idempotencyKey: receipt } }),
  };
  if (change === "profile") {
    view.setProfile("openai:other");
  }
  view.setScope({
    ...view.scope(),
    revision: 1,
    ...(change === "agent" && { agentId: "other" }),
    ...(change === "connection" && { generation: 2, client: createTestGatewayClient(request) }),
  });
  await waitForSolid(() => expect(first.dialog.isConnected).toBe(false));
  late.resolve(prepared(keyA));
  await tick(6000);
  first.button.click();
  expect(previews()).toHaveLength(1);
  expect(writes()).toHaveLength(0);
});

it("Cancel returns focus; a late ticket cannot enable the reopened dialog", async () => {
  const { io, request, writes, previews } = fixture(),
    view = mount(request);
  const old = createDeferredCore<Awaited<ReturnType<typeof io.prepare>>>();
  io.prepare = () => old.promise;
  const before = await open(view);
  before.cancel.click();
  await waitForSolid(() => expect(document.activeElement).toBe(before.trigger));
  io.prepare = async ({ idempotencyKey }) => prepared(idempotencyKey, receipt);
  const second = await open(view);
  old.resolve(prepared(previews()[0]!.idempotencyKey));
  await tick(5000);
  second.button.click();
  expect(writes()).toEqual([{ ...previews()[1], confirmationId: receipt }]);
});

it.each([
  "accountLabel",
  "workspaceId",
  "memberId",
  "accountBinding",
  "readOnly",
  "countOnly",
] as const)("makes %s-incomplete or read-only balances display only", async (missing) => {
  const { io, request, previews } = fixture();
  if (missing === "readOnly") {
    io.balance.readOnly = true;
  } else if (missing === "countOnly") {
    delete io.balance.creditId;
  } else {
    delete io.balance[missing];
  }
  const view = mount(request);
  await waitForSolid(() => expect(view.container.textContent).toContain("Reset credits: 2"));
  expect(view.queryByRole("button")).toBeNull();
  expect(previews()).toHaveLength(0);
});

it.each([
  "offline",
  "offline retry",
  "request-start-timeout retry",
  "rejected",
  "gateway-suspending",
  "request-start-timeout",
  "unavailable",
  "unmarked start timeout",
  "sent timeout",
])(
  "reports %s independently of another account receipt and retains any original uncertain intent",
  async (kind) => {
    const { io, request, writes } = fixture();
    using notify = vi.spyOn(toasts, "showToast").mockReturnValue(true);
    const retry = kind.endsWith(" retry");
    const reason = kind.replace(/ retry$/, "");
    const denied =
      !retry && !["unavailable", "sent timeout", "unmarked start timeout"].includes(reason);
    const lastReset = { creditId: "B", idempotencyKey: receipt, outcome: "reset" as const };
    io.connected = reason !== "offline";
    io.balance = offered("A", {
      lastReset,
      ...(retry && { pending: { creditId: "A", idempotencyKey: keyA } }),
    });
    io.spend = async () => {
      io.balance = offered("C", { lastReset });
      if (reason === "sent timeout") {
        throw sentTimeout(consume);
      }
      // Even identical human-readable text cannot make generic UNAVAILABLE a refusal.
      const failure = new GatewayRequestError({
        code: reason === "rejected" ? "INVALID_REQUEST" : "UNAVAILABLE",
        message: "Reset not sent",
        retryable: reason !== "unmarked start timeout",
        details: { reason: reason === "unmarked start timeout" ? "request-start-timeout" : reason },
      });
      retainGatewayResponsePayload(failure, undefined);
      throw failure;
    };
    const view = mount(request);
    await send(view, retry ? retryName : actionName);
    await waitForStatus(view, denied ? "Reset request not sent" : unknownOutcome);
    expectContent(view.container, [], ["Latest account receipt", "Limits reset."]);
    expect(notify).not.toHaveBeenCalled();
    expect(writes()).toHaveLength(1);
    if (!denied) {
      expect(view.queryByRole("button", { name: actionName })).toBeNull();
    } else if (io.connected) {
      await send(view);
      expect(writes()[1]).toMatchObject({ creditId: "C", afterReset: receipt });
    }
  },
);

it.each([true, false])(
  "recent A receipt settles our uncertain A while B is pending or finished (%s); an unavailable journal never implies settlement",
  async (pending) => {
    const { io, request, writes, previews } = fixture();
    io.spend = async () => {
      io.balance = { ...account, journalUnavailable: true, creditId: "C", availableCount: 1 };
      throw new Error("response lost");
    };
    const view = mount(request);
    await send(view);
    const status = view.getByRole("status");
    await waitForSolid(() => expect(status.textContent).toContain("Reset history is unavailable"));
    expect(status.textContent).toContain(unknownOutcome);
    expect(view.queryByRole("button", { name: retryName })).toBeNull();
    expect(view.queryByRole("button", { name: actionName })).toBeNull();
    const a = {
      creditId: "A",
      idempotencyKey: writes()[0]!.idempotencyKey,
      outcome: "alreadyRedeemed" as const,
    };
    const b = { creditId: "B", idempotencyKey: receipt, outcome: "noCredit" as const };
    // Only the exact A/key receipt settles A; the latest account activity can differ.
    io.balance = offered("C", {
      lastReset: b,
      recentReceipts: [b, a],
      ...(pending && { pending: { creditId: "D", idempotencyKey: keyA } }),
    });
    refreshView(view);
    const next = await open(view, pending ? retryName : actionName);
    expectContent(
      view.container,
      [],
      [unknownOutcome, "Already reset.", "Selected credit unavailable."],
    );
    expect(previews()[1]).toMatchObject(
      pending ? { creditId: "D", idempotencyKey: keyA } : { creditId: "C", afterReset: receipt },
    );
    io.balance = { availableCount: 0 };
    refreshView(view);
    await waitForSolid(() => expect(next.dialog.isConnected).toBe(false));
    expect(status.textContent?.trim()).toBe("");
    expect(writes()).toHaveLength(1);
  },
);

it.each(["cache-first", "detail-first", "cache-miss", "stale-detail"])(
  "fast quota race: %s never masks or delays authoritative detail",
  async (order) => {
    const cached = createDeferredCore<UsageSummary & { stale?: boolean }>(),
      detail = createDeferredCore<UsageSummary & { stale?: boolean }>();
    const request = createGatewayRequestMock(async (_method, params) =>
      (params as { quotaOnly?: boolean }).quotaOnly ? cached.promise : detail.promise,
    );
    const view = mount(request, { cacheAvailable: true });
    await waitForSolid(() => expect(request).toHaveBeenCalledTimes(2));
    if (order === "cache-first") {
      cached.resolve({ ...snapshot(70), stale: true });
      await waitForSolid(() => expect(view.container.textContent).toContain("30% left"));
      expect(view.container.textContent).toContain("Last known limits");
    }
    if (order === "cache-miss") {
      cached.resolve({ updatedAt: 1, providers: [] });
    }
    detail.resolve({ ...snapshot(20), stale: order === "stale-detail" });
    await waitForSolid(() => expect(view.container.textContent).toContain("80% left"));
    cached.resolve({ ...snapshot(70), stale: true });
    await Promise.resolve();
    flush();
    expect(view.container.textContent).not.toContain("30% left");
    expect(view.container.textContent?.includes("Last known limits")).toBe(
      order === "stale-detail",
    );
  },
);

it.each(["expired", "invalid wait", "changed key", "changed retry key", "prepare timeout"])(
  "an %s ticket cannot dispatch, and its expiry never prepares another",
  async (mode) => {
    const { io, request, previews, writes } = fixture();
    const retry = mode === "changed retry key";
    if (retry) {
      io.balance.pending = { creditId: "A", idempotencyKey: keyA };
    }
    io.prepare = async ({ idempotencyKey }) => {
      if (mode === "prepare timeout") {
        throw sentTimeout(prepare);
      }
      return {
        ...ticket,
        idempotencyKey: mode.startsWith("changed") ? receipt : idempotencyKey,
        waitMs: mode === "invalid wait" ? 2 : 5000,
        expiresInMs: 8000,
      };
    };
    const view = mount(request);
    const confirm = await open(view, retry ? retryName : actionName);
    await tick(5000);
    expect(confirm.button.disabled).toBe(mode !== "expired");
    await tick(3000);
    expect(confirm.button.disabled).toBe(true);
    expect(confirm.dialog.textContent).toContain(
      mode === "expired" ? "Confirmation expired" : "Couldn’t prepare",
    );
    confirm.button.click();
    expect(previews()).toHaveLength(1);
    expect(writes()).toHaveLength(0);
  },
);

it.each([
  { afterReset: null, expired: false },
  { afterReset: receipt, expired: false },
  { afterReset: receipt, expired: true },
])(
  "recovers only the original key after frame loss (predecessor $afterReset, expired $expired)",
  async ({ afterReset, expired }) => {
    using notify = vi.spyOn(toasts, "showToast").mockReturnValue(true);
    using storage = vi
      .spyOn(browserStorage, "getSafeSessionStorage")
      .mockReturnValue(createStorageMock());
    const { io, request, previews, writes } = fixture();
    const lastReset = afterReset
      ? { creditId: "prior", idempotencyKey: afterReset, outcome: "reset" as const }
      : undefined;
    const a = { creditId: "A", expiresAt: null },
      b = { creditId: "B", expiresAt: null };
    io.balance = offered("A", { availableCount: 2, offers: [a, b], lastReset });
    io.spend = async () => {
      throw new Error("Connection lost before Gateway admission");
    };
    const view = mount(request);
    await send(view);
    await waitForStatus(view, unknownOutcome);
    const original = previews()[0]!;
    expect(original).toMatchObject({ creditId: "A", ...(afterReset && { afterReset }) });
    // Reconnect, then reload from this tab's storage; the newly preferred B is not our target.
    io.balance = {
      ...io.balance,
      availableCount: expired ? 1 : 2,
      offers: expired ? [b] : [b, a],
      creditId: "B",
    };
    view.setScope({ ...view.scope(), generation: 1, client: createTestGatewayClient(request) });
    await waitForSolid(() => expect(view.getByRole("button", { name: retryName })).toBeTruthy());
    view.unmount();
    const restored = mount(request);
    await waitForStatus(restored, unknownOutcome);
    expect(previews()).toHaveLength(1);
    expect(writes()).toHaveLength(1);
    io.prepare = async ({ idempotencyKey }) => prepared(idempotencyKey, keyA);
    io.spend = async ({ creditId, idempotencyKey }) => {
      const outcome = expired ? "notOffered" : "reset";
      io.balance = offered("B", { lastReset: { creditId, idempotencyKey, outcome } });
      return { outcome };
    };
    const retry = await open(restored, retryName);
    expect(previews()[1]).toEqual(original);
    expectContent(retry.dialog, ["can spend 1 credit", "won’t spend a second credit"]);
    await tick(4999);
    expect(retry.button.disabled).toBe(true);
    await tick(1);
    expect(writes()).toHaveLength(1);
    retry.button.click();
    await waitForSolid(() =>
      expect(notify.mock.calls.map(([toast]) => toast.message)).toEqual([
        expired ? "Reset not sent. Nothing spent." : "Reset confirmed.",
      ]),
    );
    expect(writes()).toEqual([
      { ...original, confirmationId },
      { ...original, confirmationId: keyA },
    ]);
    await waitForSolid(() =>
      expect(restored.getByRole("button", { name: actionName })).toBeTruthy(),
    );
    expect(storage).toHaveBeenCalled();
  },
);

it("reload preserves unknown A across a shared B retry; only A’s journal can authorize recovery or settle it", async () => {
  const storage = window.sessionStorage;
  using spy = vi.spyOn(browserStorage, "getSafeSessionStorage").mockReturnValue(storage);
  const { io, request, previews, writes } = fixture();
  const held = createDeferredCore<{ outcome: string }>();
  io.spend = () => held.promise;
  const gateway = "wss://example.test/openclaw?route=not-for-storage";
  const original = mount(request, { gatewayUrl: gateway });
  await send(original);
  const saved = Object.keys(storage).filter((k) => k.startsWith("openclaw.control.codexReset."));
  expect(saved).toHaveLength(1);
  expect(saved[0]).not.toContain("route=");
  const a = { creditId: "A", idempotencyKey: writes()[0]!.idempotencyKey };
  const savedIntent = () => JSON.parse(storage.getItem(saved[0]!)!);
  const storedA = { ...a, afterReset: null };
  expect(savedIntent()).toEqual(storedA);
  original.unmount();
  // An older tab stored the key and credit without witnessing the original predecessor.
  storage.setItem(saved[0]!, JSON.stringify(a));
  const legacy = mount(request, { gatewayUrl: gateway });
  await waitForStatus(legacy, unknownOutcome);
  expect(legacy.queryByRole("button", { name: retryName })).toBeNull();
  legacy.unmount();
  storage.setItem(saved[0]!, JSON.stringify(storedA));
  io.balance = offered("B");
  const elsewhere = mount(request, { gatewayUrl: gateway, principal: "other-principal" });
  await waitForSolid(() =>
    expect(elsewhere.getByRole("button", { name: actionName })).toBeTruthy(),
  );
  elsewhere.unmount();
  const recovered = mount(request, { gatewayUrl: gateway });
  const alias = { agentId: "other", profileId: "openai:alias", accountBinding: "binding-A" };
  recovered.setScope({ ...recovered.scope(), agentId: alias.agentId });
  recovered.setProfile(alias.profileId);
  await waitForStatus(recovered, unknownOutcome);
  expect(recovered.getByRole("button", { name: retryName })).toBeTruthy();
  expect(recovered.queryByRole("button", { name: actionName })).toBeNull();
  expect(previews()).toHaveLength(1);
  expect(writes()).toHaveLength(1);

  // Another tab admitted B. Its confirmed retry is shared activity, not A’s result.
  const b = { creditId: "B", idempotencyKey: receipt };
  const shared = createDeferredCore<{ outcome: string }>();
  io.spend = () => shared.promise;
  io.quotas = accountSnapshot({ error: "Quota unavailable" });
  io.balance = { ...account, creditId: "C", pending: b }; // no offer count during the outage
  refreshView(recovered);
  await waitForStatus(recovered, "Account reset pending.");
  const retry = await open(recovered, retryName);
  expectContent(recovered.container, ["Quota unavailable"], ["Reset credits:"]);
  expectContent(retry.dialog, [
    "Expiry unknown",
    "can spend 1 credit",
    "won’t spend a second credit",
  ]);
  await tick(5000);
  expect(writes()).toHaveLength(1);
  retry.button.click();
  flush();
  expect(writes()[1]).toEqual({ ...alias, ...b, confirmationId });
  expect(savedIntent()).toEqual(storedA);
  // Even if A is offered again and its receipt has rotated out, B must never become A’s predecessor.
  io.balance = offered("A", { lastReset: { ...b, outcome: "reset" } });
  shared.resolve({ outcome: "reset" });
  await waitForContent(
    recovered,
    ["Reset credits: 1", unknownOutcome],
    ["Account reset pending.", "Limits reset."],
  );
  expect(savedIntent()).toEqual(storedA);
  expect(recovered.queryByRole("button", { name: retryName })).toBeNull();
  // An exact pending A is independently recoverable even after B completed.
  io.balance = { ...io.balance, pending: a };
  refreshView(recovered);
  await open(recovered, retryName);
  expect(previews()[2]).toEqual({ ...alias, ...a });
  io.balance = offered("C", { lastReset: { ...a, outcome: "notOffered" } });
  refreshView(recovered);
  const next = await open(recovered);
  expect(next.button.disabled).toBe(true);
  expect(previews()[3]).toMatchObject({ creditId: "C", afterReset: a.idempotencyKey });
  expect(writes()).toHaveLength(2);
  held.resolve({ outcome: "reset" });
  await tick(0);
  expect(spy).toHaveBeenCalled();
});

it("requires new consent for a different credit after another tab completes B while A is unknown", async () => {
  using notify = vi.spyOn(toasts, "showToast").mockReturnValue(true);
  const tabStorage = createStorageMock();
  using storage = vi.spyOn(browserStorage, "getSafeSessionStorage").mockReturnValue(tabStorage);
  const { io, request, previews, writes } = fixture();
  const opaque = "-opaque".repeat(23);
  const originalId = "first" + opaque,
    otherId = "other" + opaque,
    replacementId = "new" + opaque;
  io.balance = offered(originalId);
  let delayedReceipt: ResetCreditBalance["lastReset"];
  io.spend = async ({ creditId, idempotencyKey }) => {
    const completed = { creditId, idempotencyKey, outcome: "reset" } as const;
    if (creditId === replacementId) {
      delayedReceipt = completed; // The journal returns this result after the tab reloads.
    }
    if (creditId !== otherId) {
      throw new Error("Response lost");
    }
    io.balance = offered(originalId, { lastReset: completed });
    return completed;
  };
  const original = mount(request);
  await send(original);
  await waitForStatus(original, unknownOutcome);
  original.unmount();
  const stored = () => JSON.parse(tabStorage.getItem(tabStorage.key(0)!)!);
  const a = { creditId: originalId, idempotencyKey: writes()[0]!.idempotencyKey, afterReset: null };
  storage.mockReturnValue(createStorageMock()); // An independent tab on the same Gateway account.
  io.balance = offered(otherId);
  const other = mount(request);
  await send(other);
  await waitForSolid(() =>
    expect(notify.mock.calls.map(([toast]) => toast.message)).toEqual([
      "Limits reset. 1 credit spent.",
    ]),
  );
  other.unmount();
  storage.mockReturnValue(tabStorage);
  const view = mount(request);
  await waitForStatus(view, unknownOutcome);
  expectContent(view.container, [], ["Latest account receipt", "Limits reset."]);
  expect(view.queryByRole("checkbox")).toBeNull(); // Only A is offered; never rebind it to B.
  expect(view.queryByRole("button", { name: actionName })).toBeNull();
  expect(view.queryByRole("button", { name: retryName })).toBeNull();
  io.balance = {
    ...io.balance,
    availableCount: 2,
    offers: [originalId, replacementId].map((creditId) => ({ creditId, expiresAt: null })),
  };
  refreshView(view);
  const ack = await waitForSolid(() =>
    view.getByRole<HTMLInputElement>("checkbox", {
      name: /earlier credit may already have been spent/,
    }),
  );
  expectContent(view.container, [], [originalId, otherId, replacementId]);
  ack.click();
  flush();
  expect(view.getByRole("button", { name: actionName })).toBeTruthy();
  expect(stored()).toEqual(a);
  view.unmount();
  const back = mount(request);
  const again = await waitForSolid(() => back.getByRole<HTMLInputElement>("checkbox"));
  expect(again.checked).toBe(false);
  again.click();
  flush();
  expect(previews().map((p) => p.creditId)).toEqual([originalId, otherId]);
  const c = await open(back);
  expectContent(
    c.dialog,
    ["earlier credit may already have been spent", "different credit"],
    [originalId, otherId, replacementId],
  );
  const intent = previews()[2]!;
  expect(intent).toMatchObject({
    creditId: replacementId,
    afterReset: writes()[1]!.idempotencyKey,
  });
  expect([a.idempotencyKey, intent.afterReset]).not.toContain(intent.idempotencyKey);
  await tick(4999);
  expect(c.button.disabled).toBe(true);
  expect(writes().map((p) => p.creditId)).toEqual([originalId, otherId]);
  await tick(1);
  c.button.click();
  c.button.click();
  await waitForStatus(back, unknownOutcome);
  expect(tabStorage.length).toBe(1); // Only the new confirmed intent now needs this slot.
  expect(stored()).toEqual({
    creditId: replacementId,
    idempotencyKey: intent.idempotencyKey,
    afterReset: intent.afterReset,
  });
  back.unmount();
  io.balance = offered(originalId, { lastReset: delayedReceipt });
  const settled = mount(request);
  await waitForSolid(() => expect(tabStorage.length).toBe(0));
  expectContent(
    settled.container,
    ["Reset credits: 1"],
    [unknownOutcome, "Reset receipt", "Limits reset."],
  );
  expect(notify).toHaveBeenCalledTimes(1); // Only B's local confirm; never A/C's reconciliation.
  expect(notify.mock.calls[0]?.[0].signal?.aborted).toBe(true);
  expect(previews()).toHaveLength(3);
  expect(writes()[2]).toEqual({ ...intent, confirmationId });
  expect(writes().map((p) => p.creditId)).toEqual([originalId, otherId, replacementId]);
});

it("lists offers in server order, starts fresh consent on selection changes, and identifies the credit, expiry and blocking window", async () => {
  const { io, request, previews, writes } = fixture();
  vi.useFakeTimers({
    toFake: ["Date", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "performance"],
  });
  const expiry = Date.UTC(2039, 0, 19, 12) / 1000;
  io.balance = {
    ...account,
    accountEmail: undefined,
    availableCount: 2,
    offers: [
      { creditId: "first", expiresAt: expiry },
      { creditId: "second", expiresAt: null },
    ],
  };
  io.quotas.providers[0]!.windows = [
    { label: "5h", usedPercent: 100, resetAt: Date.now() + 2000 },
    { label: "weekly", usedPercent: 70, resetAt: Date.now() + 1000 },
  ];
  const view = mount(request);
  const first = await open(view);
  const disclosures = first.dialog.querySelectorAll("details");
  expect(disclosures).toHaveLength(1);
  const details = disclosures[0]!;
  expect(details.open).toBe(false);
  expectContent(details, ["Credit 1 of 2", "2039"]);
  const memberScope = `${account.memberId} · Workspace: ${account.workspaceId}`;
  expect(view.getByText(memberScope).closest("details")).toBeNull();
  expect(first.dialog.textContent).toMatch(/5-hour limit resets for free (at|on) /);
  details.querySelector("summary")!.click();
  expect(details.open).toBe(true);
  const chooser = first.dialog.querySelector("select")!;
  expect([...chooser.options].map((o) => o.textContent)).toEqual([
    expect.stringContaining("Credit 1 of 2"),
    expect.stringContaining("Credit 2 of 2"),
  ]);
  await tick(5000);
  expect(first.dialog.textContent).not.toContain("5-hour limit resets for free");
  chooser.selectedIndex = 1;
  chooser.dispatchEvent(new Event("change", { bubbles: true }));
  flush();
  expect(first.dialog.isConnected).toBe(true);
  first.button.click();
  expect(writes()).toHaveLength(0);
  expect(first.button.disabled).toBe(true);
  expect(first.dialog.textContent).toContain("No expiry");
  // A separate tab can review A without sharing or replacing this selection of B.
  const other = mount(request);
  const otherDialog = await open(other);
  expect(otherDialog.button.disabled).toBe(true);
  expect(previews()[2]!.creditId).toBe("first");
  expect(first.dialog.isConnected).toBe(true);
  expect(previews()[1]).toMatchObject({ creditId: "second" });
  expect(previews()[1]!.idempotencyKey).not.toBe(previews()[0]!.idempotencyKey);
  await tick(5000);
  first.button.click();
  expect(writes()).toEqual([{ ...previews()[1], confirmationId }]);
});

it("never notifies for a peer receipt, cancellation or a late result after credential replacement", async () => {
  using notify = vi.spyOn(toasts, "showToast").mockReturnValue(true);
  const { io, request, writes } = fixture();
  io.balance.lastReset = { creditId: "peer", idempotencyKey: receipt, outcome: "reset" };
  const view = mount(request);
  await waitForContent(view, ["Reset credits: 2"], ["Latest account receipt", "Limits reset."]);
  (await open(view)).cancel.click();
  const held = createDeferredCore<{ outcome: string }>();
  io.spend = () => held.promise;
  await send(view);
  view.setScope({ ...view.scope(), credentialRevision: 1 });
  io.balance = { ...account, accountBinding: "binding-new", availableCount: 0 };
  await waitForSolid(() => expect(view.container.textContent).toContain("Reset credits: 0"));
  held.resolve({ outcome: "reset" });
  await tick(0);
  expect(notify).not.toHaveBeenCalled();
  expect(writes()).toHaveLength(1);
});

it.each(["stale", "failed", "failed retry", "failed unconfirmed", "failed before reply"])(
  "keeps the reset outcome separate from a %s post-reset quota read",
  async (mode) => {
    using notify = vi.spyOn(toasts, "showToast").mockReturnValue(true);
    const retry = mode === "failed retry";
    const message = retry
      ? "Already reset. No additional credit spent."
      : "Limits reset. 1 credit spent.";
    const failure = "Limits unavailable for this account";
    const held = createDeferredCore();
    const id = "offer-" + "0123456789abcdef".repeat(7);
    const pending = retry ? { creditId: id, idempotencyKey: keyA } : undefined;
    let limitsRestored: boolean | "unavailable" = false;
    const { io, request, writes } = fixture(async ({ quotaOnly }) => {
      if (quotaOnly) {
        return snapshot(70);
      }
      if (!writes().length) {
        return { ...snapshot(45), resetCredits: offered(id, { pending }) };
      }
      await held.promise;
      if (limitsRestored === true) {
        return { ...snapshot(0), resetCredits: { ...account, availableCount: 0 } };
      }
      if (mode !== "stale" || limitsRestored === "unavailable") {
        throw new Error(failure);
      }
      return { ...snapshot(70), stale: true, resetCredits: { ...account } };
    });
    const reply = createDeferredCore();
    io.spend = async () => {
      if (mode === "failed before reply") {
        await reply.promise;
      }
      if (mode === "failed unconfirmed") {
        throw sentTimeout(consume);
      }
      return { outcome: retry ? "alreadyRedeemed" : "reset" };
    };
    const lateReply = mode === "failed before reply";
    const view = mount(request, { cacheAvailable: !lateReply });
    await send(view, retry ? retryName : actionName);
    if (lateReply) {
      refreshView(view);
      held.resolve();
      await waitForContent(view, [failure], [actionName, retryName]);
      expect(notify).not.toHaveBeenCalled();
      reply.resolve();
    }
    if (mode === "failed unconfirmed") {
      held.resolve();
      await waitForStatus(view, unknownOutcome, "Refresh usage");
      expectContent(view.container, [failure], ["Reset receipt", actionName, retryName]);
      expect(writes()).toHaveLength(1);
      expect(notify).not.toHaveBeenCalled();
      return;
    }
    await waitForSolid(() =>
      expect(notify.mock.calls.map(([t]) => [t.severity, t.message])).toEqual([
        [retry ? "info" : "success", message],
      ]),
    );
    if (!lateReply) {
      expectContent(view.getByRole("status"), [], [message, id]);
    }
    held.resolve();
    const quota = lateReply
      ? [failure]
      : ["Last known limits", "30% left", ...(mode === "stale" ? [] : [failure])];
    const absent = [
      id,
      "Updating limits",
      actionName,
      retryName,
      ...(lateReply ? ["% left", unknownOutcome] : []),
    ];
    await waitForContent(view, quota, absent);
    await waitForStatus(view, message, "Refresh usage");
    expect(view.getByText(message).closest("details")).toBeNull();
    if (mode === "stale") {
      limitsRestored = true;
      view.getByRole<HTMLButtonElement>("button", { name: "Refresh usage" }).click();
      await waitForContent(
        view,
        ["100% left", "Reset credits: 0"],
        [message, "Last known limits", "Refresh usage"],
      );
      // A later outage is not another debit and must not resurrect old success copy.
      for (const state of [false, "unavailable"] as const) {
        limitsRestored = state;
        refreshView(view);
        await waitForContent(
          view,
          [state ? failure : "30% left"],
          ["100% left", message, "Refresh usage"],
        );
      }
    }
    expect(notify).toHaveBeenCalledTimes(1);
    expect(writes()).toHaveLength(1);
    if (retry) {
      expect(view.container.textContent).not.toContain("1 credit spent");
      expect(writes()[0]).toMatchObject({ ...row, ...pending, confirmationId });
      view.setScope({ ...view.scope(), credentialRevision: 1 });
      await waitForContent(view, [failure], [message]);
    }
  },
);

it("keeps reset counts, review and completion on the selected account across reordering", async () => {
  const ids = ["openai:a", "openai:b", "openai:c"],
    b = ids[1]!;
  const [order, setOrder] = createSignal(ids);
  const refreshed = createDeferredCore(),
    spent = createDeferredCore<{ outcome: string }>();
  let refreshing = false,
    balance = 2;
  const { io, request, previews, writes } = fixture(async ({ profileId, quotaOnly }) => {
    if (quotaOnly) {
      return snapshot(75);
    }
    if (profileId !== b) {
      return {
        ...snapshot(0, 0),
        resetCredits: profileId === ids[0] ? { availableCount: 0 } : undefined,
      };
    }
    if (refreshing) {
      await refreshed.promise;
    }
    return {
      ...snapshot(100, 42219.4424345),
      resetCredits: offered("credit-b", { availableCount: balance }),
    };
  });
  io.spend = () => spent.promise;
  const view = mount(request, { order, cacheAvailable: true });
  const track = (label: string) =>
    [
      ...view
        .getByRole("group", { name: label })
        .querySelectorAll(".model-providers__credit [aria-hidden]"),
    ].map((c) => c.textContent);
  const select = (id: string) => {
    view.getByRole("button", { name: "Account details: " + id }).click();
    flush();
  };
  await waitForSolid(() => expect(track("Reset credits")).toEqual(["0", "2", "—"]));
  expect(track("Credits")).toEqual(["0", "42,219", "0"]);
  expect(request).toHaveBeenCalledTimes(6); // one detail and one cache read per account
  const { dialog, button } = await open(view, /Use reset credit/);
  expectContent(dialog, [account.memberId, account.workspaceId], ["credit-b"]);
  const identity = `${b} · ${account.accountEmail} · Workspace: ${account.workspaceId}`;
  expect(view.getByText(identity).closest("details")).toBeNull();
  refreshing = true;
  setOrder([b, ids[0]!, ids[2]!]);
  refreshView(view);
  await waitForContent(view, ["Last known limits"]);
  expect(track("Reset credits")).toEqual(["2", "0", "—"]);
  refreshed.resolve();
  await waitForContent(view, [], ["Last known limits"]);
  expect(view.getByRole("dialog")).toBe(dialog);
  expect(button.disabled).toBe(true);
  await tick(5000);
  button.click();
  flush();
  select(ids[0]!);
  expectContent(
    view.container.querySelector('[data-profile-id="openai:a"]'),
    [],
    ["Reset credits:", "credit-b", "Waiting for Codex"],
  );
  balance = 1;
  spent.resolve({ outcome: "reset" });
  await waitForSolid(() => expect(track("Reset credits")).toEqual(["1", "0", "—"]));
  expect(previews()).toEqual([
    {
      ...row,
      profileId: b,
      accountBinding: account.accountBinding,
      creditId: "credit-b",
      idempotencyKey: expect.any(String),
    },
  ]);
  expect(writes()).toEqual([{ ...previews()[0], confirmationId }]);
  expect(request.mock.calls.filter(([m]) => m === usage)).toHaveLength(14);
});
