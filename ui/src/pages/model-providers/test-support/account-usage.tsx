import { createSignal } from "solid-js";
import {
  createTestGatewayClient,
  type createGatewayRequestMock,
} from "../../../test-helpers/gateway-client.ts";
import { profile as makeProfile } from "../../../test-helpers/model-providers.ts";
import { mountSolid } from "../../../test-helpers/mount-solid.ts";
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
