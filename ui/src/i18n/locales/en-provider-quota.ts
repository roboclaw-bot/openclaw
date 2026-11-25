import { mergeCatalog } from "../lib/merge-catalog.ts";
import type { TranslationMap } from "../lib/types.ts";
import { en } from "./en.ts";

// The quota popover and Models settings share window labels, not the composer catalog.
const catalog = {
  chat: {
    composer: {
      contextUsage: {
        resets: "Resets {time}",
        usageCredits: "Usage credits",
        budgetValue: "{used} of {limit}",
        limitFiveHour: "5-hour",
        limitWeekly: "Weekly",
        limitDaily: "Daily",
        limitHours: "{hours}-hour",
      },
    },
  },
} satisfies TranslationMap;

export const registerProviderQuotaEnglish = Object.assign(() => mergeCatalog(en, catalog), {
  catalog,
});
