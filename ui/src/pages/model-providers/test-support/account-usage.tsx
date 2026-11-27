import { createSignal } from "solid-js";
import { expect, vi } from "vitest";
import {
  createTestGatewayClient,
  type createGatewayRequestMock,
} from "../../../test-helpers/gateway-client.ts";
import { profile as makeProfile } from "../../../test-helpers/model-providers.ts";
import { mountSolid } from "../../../test-helpers/mount-solid.ts";
import { flush, waitForSolid } from "../../../test-helpers/solid-settle.ts";
import { AccountLimits, createAccountUsage, type AccountUsageScope } from "../account-usage.tsx";
import { ProviderProfiles } from "../profiles-view.tsx";
import { resetRegistryFor } from "../reset-credit-operation.ts";
import { card, props as providerProps } from "../view.test-support.tsx";

export function mountAccountUsage(
  request: ReturnType<typeof createGatewayRequestMock>,
  options: {
    gatewayUrl?: string;
    principal?: string;
    cacheAvailable?: boolean;
    order?: () => string[];
  } = {},
) {
  const client = createTestGatewayClient(request);
  const { gatewayUrl = client.gatewayUrl, principal = client.recoveryScope } = options;
  const [scope, setScope] = createSignal<AccountUsageScope>({
    client,
    agentId: "main",
    revision: 0,
    generation: 0,
    cacheAvailable: options.cacheAvailable ?? false,
    registry: resetRegistryFor({}, gatewayUrl, principal),
    canConsume: () => true,
  });
  const [profile, setProfile] = createSignal("openai:account");
  const { order } = options;
  const ids = order?.();
  const profiles = () => ids?.map((id) => makeProfile(id, { displayName: id }));
  const view = mountSolid(() => {
    if (order) {
      return (
        <ProviderProfiles
          {...providerProps()}
          card={card({ profiles: profiles(), profileOrders: { openai: order() } })}
          accountUsage={scope()}
        />
      );
    }
    const read = createAccountUsage(scope, profile);
    return <AccountLimits read={read} />;
  });
  return { ...view, scope, setScope, setProfile };
}

export const useResetCredit = "Use reset credit";
export async function openReset(
  view: ReturnType<typeof mountAccountUsage>,
  name: string | RegExp = useResetCredit,
) {
  const trigger = await waitForSolid(() => {
    const button = view.getByRole<HTMLButtonElement>("button", { name });
    expect(button.disabled).toBe(false);
    return button;
  });
  trigger.click();
  const dialog = await waitForSolid(() => view.getByRole("dialog"));
  const button = dialog.querySelector<HTMLButtonElement>("button.danger")!;
  const cancel = view.getByRole<HTMLButtonElement>("button", { name: "Cancel" });
  return { dialog, button, cancel, trigger };
}
export const advanceClock = async (ms: number) => {
  await vi.advanceTimersByTimeAsync(ms);
  flush();
};
export async function confirmReset(
  view: ReturnType<typeof mountAccountUsage>,
  name = useResetCredit,
) {
  const confirm = await openReset(view, name);
  await advanceClock(5000);
  expect(confirm.button.disabled).toBe(false);
  confirm.button.click();
  flush();
}
export const refreshAccountUsage = (view: ReturnType<typeof mountAccountUsage>) =>
  view.setScope({ ...view.scope(), revision: view.scope().revision + 1 });
