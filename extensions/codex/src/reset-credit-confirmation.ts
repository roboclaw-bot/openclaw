import { randomUUID } from "node:crypto";

const waitMs = 5_000;
const lifetimeMs = 120_000;
type Selection = {
  accountBinding: string;
  creditId: string;
  idempotencyKey: string;
  afterReset?: string;
  agentId: string;
  profileId: string;
};
/** One expiring, non-spending dialog per connection; never reserve a subscription on open. */
export class ResetConfirmations {
  private readonly tickets = new WeakMap<
    object,
    { id: string; selection: Selection; comparison?: string; opened: number }
  >();
  begin(client: object, selection: Selection) {
    const id = randomUUID();
    this.tickets.set(client, { id, selection, opened: 0 });
    return (comparison: string) => {
      const ticket = this.tickets.get(client);
      if (ticket?.id !== id) {
        throw new Error("This dialog was replaced.");
      }
      ticket.comparison = comparison;
      ticket.opened = performance.now();
      return {
        confirmationId: id,
        idempotencyKey: selection.idempotencyKey,
        waitMs,
        expiresInMs: lifetimeMs,
      };
    };
  }
  take(client: object, target: Selection & { confirmationId: string }) {
    const ticket = this.tickets.get(client);
    if (ticket?.comparison === undefined || ticket.id !== target.confirmationId) {
      return undefined;
    }
    const age = performance.now() - ticket.opened;
    const s = ticket.selection;
    if (
      age < waitMs ||
      age >= lifetimeMs ||
      s.accountBinding !== target.accountBinding ||
      s.creditId !== target.creditId ||
      s.idempotencyKey !== target.idempotencyKey ||
      s.afterReset !== target.afterReset ||
      s.agentId !== target.agentId ||
      s.profileId !== target.profileId
    ) {
      return undefined;
    }
    this.tickets.delete(client);
    return { comparison: ticket.comparison };
  }
}
