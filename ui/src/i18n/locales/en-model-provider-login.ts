import { mergeCatalog } from "../lib/merge-catalog.ts";
import type { TranslationMap } from "../lib/types.ts";
import { en } from "./en.ts";

const catalog = {
  modelProviderLogin: {
    remoteCodex: {
      description: "ChatGPT subscription",
      action: "Sign in to Codex with a code",
      responses: "Browser sign-in for the Responses API",
    },
  },
} satisfies TranslationMap;

export const registerModelProviderLoginEnglish = Object.assign(() => mergeCatalog(en, catalog), {
  catalog,
});
