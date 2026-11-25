/** Worker-backed auth-profile selection and native provider identity. */
import {
  embeddedAgentLog,
  resolveDefaultAgentDir,
} from "openclaw/plugin-sdk/agent-harness-registration";
import {
  ensureAuthProfileStoreAsync,
  resolveAuthProfileOrder,
  type AuthProfileStore,
} from "openclaw/plugin-sdk/provider-auth";
import { resolveProviderIdForAuth } from "openclaw/plugin-sdk/provider-auth-aliases";
import {
  createCodexAuthProfileSelection,
  type CodexAppServerAuthProfileLookup,
} from "./auth-profile-selection.js";
import type { CodexAppServerPreparedAuth } from "./auth-types.js";
import { isCodexResponsesOAuth } from "./responses-oauth.js";
export {
  CODEX_APP_SERVER_AUTH_PROVIDER,
  type CodexAppServerAuthProfileLookup,
} from "./auth-profile-selection.js";

const CODEX_APP_SERVER_NATIVE_AUTH_PROVIDER = "openai";
const PUBLIC_OPENAI_MODEL_PROVIDER = "openai";

export async function resolveModelBackedReviewerPolicyProvider(params: {
  authProfileId?: string;
  modelProvider?: string;
  agentDir?: string;
  config?: CodexAppServerAuthProfileLookup["config"];
}): Promise<string | undefined> {
  const modelProvider = params.modelProvider?.trim();
  if (modelProvider && modelProvider.toLowerCase() !== "codex") {
    return modelProvider.toLowerCase() === "openai" ? "openai" : modelProvider;
  }
  return (await isCodexAppServerNativeAuthProfile(params)) ? "openai" : undefined;
}

export const {
  resolveCodexAppServerAuthProfileId,
  resolveCodexAppServerAuthProfileIdForAgent,
  resolveCodexAppServerAuthProfileStore,
  withCodexAppServerAuthProfileIdAtEffect,
} = createCodexAuthProfileSelection({
  ensureAuthProfileStoreAsync,
  resolveAuthProfileOrder,
});

export type CodexAppServerAuthRuntimeContext = CodexAppServerAuthProfileLookup & {
  authMode?: "prepared-api-key" | "pinned-member" | "profile";
  onAuthRefreshFailure?: () => void;
};

export function codexClientAuthMode(prepared: CodexAppServerPreparedAuth | undefined) {
  if (prepared?.kind === "api-key" || isCodexResponsesOAuth(prepared)) {
    return "prepared-api-key";
  }
  return prepared?.kind === "profile" && prepared.snapshot?.pinAccessToken
    ? "pinned-member"
    : "profile";
}

/** Only native subscription credentials may enter Codex account APIs. */
export function supportsCodexSubscriptionAuth(credential: AuthProfileStore["profiles"][string]) {
  return (
    credential.type === "token" ||
    (credential.type === "oauth" &&
      credential.authFlow !== "chatgpt-token-sharing" &&
      credential.authFlow !== "chatgpt-identity")
  );
}

/** Returns true when an auth profile uses native Codex/OpenAI app-server auth. */
export async function isCodexAppServerNativeAuthProfile(
  lookup: CodexAppServerAuthProfileLookup,
): Promise<boolean> {
  const authProfileId = lookup.authProfileId?.trim();
  if (!authProfileId) {
    return false;
  }
  try {
    const store =
      lookup.authProfileStore ??
      (await ensureAuthProfileStoreAsync(
        lookup.agentDir?.trim() || resolveDefaultAgentDir(lookup.config ?? {}),
        {
          allowKeychainPrompt: false,
          config: lookup.config,
          externalCliProviderIds: [CODEX_APP_SERVER_NATIVE_AUTH_PROVIDER],
          externalCliProfileIds: [authProfileId],
        },
      ));
    const credential = store.profiles[authProfileId];
    if (!credential || !supportsCodexSubscriptionAuth(credential)) {
      return false;
    }
    const provider = credential.provider?.trim();
    return Boolean(
      provider &&
      resolveProviderIdForAuth(provider, { config: lookup.config }) ===
        CODEX_APP_SERVER_NATIVE_AUTH_PROVIDER,
    );
  } catch (error) {
    embeddedAgentLog.debug("failed to resolve codex app-server auth profile provider", {
      authProfileId,
      error,
    });
    return false;
  }
}

/** Hides redundant OpenAI provider attribution for native Codex auth bindings. */
export async function normalizeCodexAppServerBindingModelProvider(
  params: CodexAppServerAuthProfileLookup & { modelProvider?: string },
): Promise<string | undefined> {
  const modelProvider = params.modelProvider?.trim();
  if (!modelProvider) {
    return undefined;
  }
  if (
    modelProvider.toLowerCase() === PUBLIC_OPENAI_MODEL_PROVIDER &&
    (await isCodexAppServerNativeAuthProfile(params))
  ) {
    return undefined;
  }
  return modelProvider;
}
