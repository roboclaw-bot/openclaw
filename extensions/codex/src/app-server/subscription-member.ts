import { sha256Hex } from "openclaw/plugin-sdk/node-crypto-runtime";
import { decodeOpenAICodexJwtPayload } from "openclaw/plugin-sdk/provider-oauth-runtime";
import { z } from "zod";
import type { CodexLoginAccountParams } from "./protocol.js";

// Match Codex get_chatgpt_account_user_id: the selected workspace and its opaque membership.
const claimId = z
  .string()
  .min(1)
  .refine((value) => value === value.trim());
const tokenClaims = z.object({
  "https://api.openai.com/auth": z.object({
    chatgpt_account_id: claimId,
    chatgpt_account_user_id: claimId,
  }),
  "https://api.openai.com/profile": z.object({ email: z.string().optional() }).optional(),
});

/** Identify the credentials actually passed to Codex, not the profile row or its cached email. */
export function codexSubscriptionMember(login: CodexLoginAccountParams | undefined) {
  if (login?.type !== "chatgptAuthTokens" || login.accessToken.split(".").length !== 3) {
    return undefined;
  }
  const claims = tokenClaims.safeParse(decodeOpenAICodexJwtPayload(login.accessToken));
  if (!claims.success) {
    return undefined;
  }
  const auth = claims.data["https://api.openai.com/auth"];
  const member = auth.chatgpt_account_user_id;
  const accountId = auth.chatgpt_account_id;
  if (accountId !== login.chatgptAccountId) {
    return undefined;
  }
  const email = claims.data["https://api.openai.com/profile"]?.email;
  return {
    memberId: member,
    workspaceId: accountId,
    accountEmail: email,
    accountBinding: sha256Hex(JSON.stringify(["codex-reset-credit", accountId, member])),
    accountLabel: [email, member, accountId].filter(Boolean).join(" · "),
  };
}
