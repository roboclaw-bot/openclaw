/* @vitest-environment jsdom */

import { beforeEach, expect, it, vi } from "vitest";
import { i18n } from "../../i18n/index.ts";
import { expectContent, profile } from "../../test-helpers/model-providers.ts";
import { flush, waitForSolid } from "../../test-helpers/solid-settle.ts";
import { buildModelProviderCards, type ModelProviderCard } from "./data.ts";
import { card, mount, props, text, usageScope } from "./view.test-support.tsx";

beforeEach(() => i18n.setLocale("en"));

it("uses the scoped check outcome without hiding catalog or account problems", () => {
  const viewProps = props({ cards: [card({ catalogStatus: "ready" })] });
  const container = mount(viewProps);
  const status = () => text(container.querySelector(".provider-row__status"));
  const probe = { provider: "openai", status: "billing" as const, results: [] };
  mount({ ...viewProps, probeResults: { openai: probe } }, container);
  expect(status()).toBe("Billing problem");
  mount({ ...viewProps, probeResults: { another: probe } }, container);
  expect(status()).toBe("Ready");
  const partial = {
    provider: "openai",
    status: "ok" as const,
    results: [{ label: "Secondary account", status: "auth" as const }],
  };
  mount({ ...viewProps, probeResults: { openai: partial } }, container);
  expect(status()).toBe("Access verified with warnings");
  for (const [catalogStatus, label] of [
    ["auth-rejected", "Credentials rejected"],
    ["unavailable", "Models unavailable"],
  ] as const) {
    mount(
      { ...viewProps, cards: [card({ catalogStatus })], probeResults: { openai: partial } },
      container,
    );
    expect(status()).toBe(label);
  }
  mount({ ...viewProps, probeResults: { openai: { ...partial, results: [] } } }, container);
  expect(status()).toBe("Ready");
});

it("preserves setup status when a probe has no model to check", () => {
  const viewProps = props({ cards: [card({ catalogStatus: "ready" })] });
  const container = mount({
    ...viewProps,
    probeResults: { openai: { provider: "openai", status: "no_model", results: [] } },
  });
  expect(text(container.querySelector(".provider-row__status"))).toBe("Ready");
  mount(
    {
      ...viewProps,
      cards: [card({ catalogStatus: "auth-rejected" })],
      probeResults: { openai: { provider: "openai", status: "no_model", results: [] } },
    },
    container,
  );
  expect(text(container.querySelector(".provider-row__status"))).toBe("Credentials rejected");
});

it.each([true, false])(
  "labels a single measured account without per-login reads (profiles visible: %s)",
  (canViewProfiles) => {
    const profiles = [profile("openai:first"), profile("openai:second")];
    const usage = { provider: "openai", displayName: "OpenAI", plan: "Team", windows: [] };
    const view = (roster = profiles, sample: ModelProviderCard["usage"] = usage) =>
      props({
        canViewProfiles,
        canMutate: false,
        cards: [card({ apiKey: undefined, profiles: roster, usage: sample })],
      });
    const container = mount(view());
    const summary = container.querySelector<HTMLButtonElement>(".provider-row__summary")!;
    expectContent(summary, [], ["Team"]);
    summary.click();
    flush();
    const limits = () => container.querySelector(".provider-row__limits-pane");
    expect(text(limits())).toMatch(/Limits for one account.*Team/u);
    const measured = { ...usage, windows: [{ label: "Week", usedPercent: 100 }] };
    mount(view(profiles, measured), container);
    expectContent(limits(), ["Limits for one account", "0% left"]);
    expectContent(summary, [], ["0% left"]);
    mount(view(profiles.slice(0, 1), measured), container);
    expect(limits()).toBeNull();
    summary.click();
    flush();
    expectContent(summary, [], ["Team", "Week 0% left"]);
  },
);

it("never assigns a retained sample to the remaining login and keeps organization billing separate", async () => {
  const first = profile("openai:workspace-a", { email: "same@example.test" });
  const native = profile("openai:workspace-b", { email: first.email });
  const connector = profile("openai:app", { email: native.email, authRequirement: "api-key" });
  const usage = {
    provider: "openai",
    displayName: "OpenAI",
    plan: "Studio Pro",
    accountEmail: first.email,
    windows: [{ label: "Week", usedPercent: 100 }],
    billing: [{ type: "balance" as const, amount: 12, unit: "credits" }],
  };
  const read = vi.fn((_id: string) => ({
    providers: [
      {
        provider: "openai",
        displayName: "OpenAI",
        plan: "Team",
        windows: [{ label: "Week", usedPercent: 45 }],
      },
    ],
  }));
  const accountUsage = usageScope(read);
  const view = (
    profiles: ModelProviderCard["profiles"],
    sample: ModelProviderCard["usage"] = usage,
  ) =>
    props({
      cards: [card({ apiKey: undefined, profiles, usage: sample, catalogStatus: "ready" })],
      accountUsage: { ...accountUsage, agentId: "writer" },
    });
  const container = mount({ ...view([first, connector, native]), accountUsage });
  const summary = container.querySelector<HTMLButtonElement>(".provider-row__summary")!;
  const limits = () => container.querySelector(".provider-row__limits-pane");
  const account = () => container.querySelector(".model-providers__account-limits");
  const toggle = () => {
    summary.click();
    flush();
  };
  const stale = [usage.plan, "0% left", "12 credits"];
  // The global sample survives the roster change. A shared email or reused slot is not a member.
  for (const authProfileId of [undefined, first.profileId, native.profileId]) {
    mount(view([native], { ...usage, authProfileId }), container);
    expectContent(summary, [native.email!, "Ready"], stale);
  }
  // An untagged error-only provider sample can be A’s stale subscription failure.
  const error = "Token expired";
  mount(
    view([native], { provider: "openai", displayName: "OpenAI", windows: [], error }),
    container,
  );
  expectContent(summary, ["Ready"], [error, "Couldn’t check usage"]);
  toggle();
  await waitForSolid(() => expectContent(account(), ["Team", "55% left"], [error]));
  expectContent(container, [], stale);
  expect(limits()).toBeNull();
  expect(container.querySelectorAll(".provider-usage__window")).toHaveLength(1);

  // usage.status omits the profile id; its retained sample can outlive the native login.
  mount(view([connector]), container);
  expect(limits()).toBeNull();
  expect(account()).toBeNull();
  expectContent(container, ["Responses API · No Codex quota"]);
  toggle();
  expectContent(summary, [connector.email!], ["Pro", "Week 0% left"]);
  toggle();
  expect(read).toHaveBeenCalledExactlyOnceWith(native.profileId);
  for (const scope of [null, { ...accountUsage, credentialRevision: "unavailable" as const }]) {
    mount(
      {
        ...view([native], { ...usage, accountEmail: undefined, plan: undefined, windows: [] }),
        accountUsage: scope,
      },
      container,
    );
    expect(limits()).toBeNull();
    expectContent(container, [], stale);
    toggle();
    expectContent(summary, [native.email!, "Ready"], stale);
    toggle();
  }
  const aggregate = {
    provider: "openai",
    displayName: "OpenAI",
    windows: [],
    summary: "Provider totals",
  };
  mount(view([connector], aggregate), container);
  expectContent(limits(), ["Provider totals"]);
  const billing = [{ type: "spend" as const, amount: 25, unit: "USD" }];
  for (const remaining of [connector, native]) {
    mount(view([remaining], { ...aggregate, plan: "Admin API", billing }), container);
    expectContent(limits(), ["$25.00"]);
    expectContent(summary, ["Admin API"]);
  }
});

it("uses catalog evidence for short-lived OAuth without treating expiry alone as sign-out", () => {
  const oauth = profile("example:account", {
    status: "expiring",
    expiry: { at: 4_000_000, remainingMs: 3_600_000, label: "1h" },
  });
  const providerCard = card({
    id: "example",
    displayName: "Example",
    apiKey: undefined,
    auth: { kind: "expiring", expiryLabel: "1h" },
    profiles: [oauth],
    catalogStatus: "ready",
  });
  const viewProps = props({ cards: [providerCard], configuredModels: [], modelRequired: true });
  const container = mount(viewProps);
  const statusAfter = (changes: Partial<ModelProviderCard>) => {
    mount({ ...viewProps, cards: [{ ...providerCard, ...changes }] }, container);
    return text(container.querySelector(".provider-row__status"));
  };
  expect(text(container.querySelector(".provider-row__status"))).toBe("Ready");
  expectContent(container.querySelector("[data-model-readiness]"), ["no usable models"]);
  // Other providers still own their own reported usage; Codex quota rules don't apply.
  expect(
    statusAfter({
      usage: {
        provider: "example",
        displayName: "Example",
        authProfileId: "example:meter",
        windows: [{ label: "Week", usedPercent: 100 }],
      },
    }),
  ).toBe("Week 0% left");
  expect(statusAfter({ catalogStatus: undefined })).toBe("");
  expect(statusAfter({ catalogStatus: "auth-rejected" })).toBe("Credentials rejected");
  // A refresh in progress keeps the catalog evidence, unlike a failed refresh.
  for (const [reasonCode, label] of [
    ["refresh_failed", "Expired"],
    ["expired", "Ready"],
  ] as const) {
    expect(
      statusAfter({
        auth: { kind: "expired" },
        profiles: [{ ...oauth, status: "expired", reasonCode, expiry: undefined }],
      }),
    ).toBe(label);
  }
  expect(statusAfter({ auth: { kind: "expired" }, profiles: [] })).toBe("Expired");
  expect(
    statusAfter({
      profiles: [oauth, profile("example:static", { type: "token", status: "expiring" })],
    }),
  ).toBe("Expiring");
  // The Gateway's rollup can exclude an unusable account from selection.
  expect(
    statusAfter({
      auth: { kind: "ok" },
      profiles: [
        { ...oauth, status: "ok" },
        profile("example:excluded", { status: "expired", reasonCode: "expired" }),
      ],
    }),
  ).toBe("Ready");
});

it("does not prescribe OAuth sign-in for a rejected API key with excluded OAuth inventory", () => {
  const cards = buildModelProviderCards({
    authStatus: {
      ts: 1,
      providers: [
        {
          provider: "example",
          displayName: "Example",
          status: "static",
          profileOrder: ["example:api-key"],
          profiles: [
            { profileId: "example:api-key", type: "api_key", status: "static" },
            {
              profileId: "example:excluded",
              type: "oauth",
              status: "expired",
              reasonCode: "expired",
            },
          ],
        },
      ],
    },
    models: [],
    providerUsage: null,
    providerOutcomes: [
      { provider: "example", profileId: "example:api-key", status: "auth-rejected" },
    ],
  });
  const container = mount(props({ cards, configuredModels: [] }));
  expect(text(container.querySelector(".provider-row__status"))).toBe("Credentials rejected");
  const excluded = container.querySelector('[data-profile-id="example:excluded"]');
  expect(text(excluded)).toContain("Refreshing");
  expect(text(excluded)).not.toContain("Sign in again");
});

it.each([
  ["missing_credential", "Not signed in"],
  ["refresh_failed", "Sign-in expired"],
  ["expired", "Refreshing"],
] as const)(
  "preserves selected static-token expiry beside an excluded OAuth %s reason",
  (reasonCode, label) => {
    const cards = buildModelProviderCards({
      authStatus: {
        ts: 1,
        providers: [
          {
            provider: "example",
            displayName: "Example",
            status: "expiring",
            profileOrder: ["example:token"],
            profiles: [
              { profileId: "example:token", type: "token", status: "expiring" },
              {
                profileId: "example:excluded",
                type: "oauth",
                status: reasonCode === "missing_credential" ? "missing" : "expired",
                reasonCode,
              },
            ],
          },
        ],
      },
      models: [],
      providerUsage: null,
    });
    const container = mount(props({ cards, configuredModels: [] }));
    expect(text(container.querySelector(".provider-row__status"))).toBe("Expiring");
    container.querySelector<HTMLButtonElement>(".provider-row__summary")!.click();
    flush();
    expect(text(container.querySelector('[data-profile-id="example:excluded"]'))).toContain(label);
  },
);

it("keeps one signal per state: the row speaks for an only account, not beside other credentials", () => {
  const failing = {
    profileId: "example:failing",
    type: "oauth" as const,
    status: "expired" as const,
    reasonCode: "refresh_failed" as const,
  };
  const rejected = {
    id: "example",
    displayName: "Example",
    apiKey: undefined,
    catalogStatus: "auth-rejected" as const,
  };
  const accountStatus = (id: string, container: HTMLElement) =>
    text(container.querySelector(`[data-profile-id="${id}"] .model-providers__profile-status`));

  const only = mount(props({ cards: [card({ ...rejected, profiles: [failing] })] }));
  expect(text(only.querySelector(".provider-row__status"))).toBe("Credentials rejected");
  expect(accountStatus(failing.profileId, only)).toBe("");

  const healthy = { profileId: "example:healthy", type: "oauth" as const, status: "ok" as const };
  const several = mount(props({ cards: [card({ ...rejected, profiles: [healthy, failing] })] }));
  expect(accountStatus(failing.profileId, several)).toBe("Sign-in expired");
  expect(accountStatus(healthy.profileId, several)).toBe("");

  // A key could be what was rejected, so the account can't be assumed to be the cause.
  const besideKey = mount(
    props({ cards: [card({ ...rejected, apiKey: { source: "config" }, profiles: [failing] })] }),
  );
  expect(accountStatus(failing.profileId, besideKey)).toBe("Sign-in expired");
});

it("counts a provider's only unavailable model in the singular", () => {
  const container = mount(
    props({ cards: [card({ modelCount: 1, availableModelCount: 0 })], configuredModels: [] }),
  );
  expect(text(container.querySelector(".provider-row__meta"))).toContain("0 of 1 model available");
  mount(
    props({ cards: [card({ modelCount: 3, availableModelCount: 2 })], configuredModels: [] }),
    container,
  );
  expect(text(container.querySelector(".provider-row__meta"))).toContain("2 of 3 models available");
});
