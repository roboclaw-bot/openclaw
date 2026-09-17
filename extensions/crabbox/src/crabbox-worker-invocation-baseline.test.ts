// Shared tests-only overlay for the identity parent and the A+B candidate.
// No V1 imports: baseline failures must describe effects, not missing SDK symbols.
import { redactToolPayloadText } from "openclaw/plugin-sdk/logging-core";
import { describe, expect, it } from "vitest";
import { operationLeaseId } from "./crabbox-worker-profile.js";
import {
  CHECKPOINT_ID,
  PROFILE,
  createProjectOptions,
  createWarmProvider,
  openWarmImageStore,
} from "./crabbox-worker-warm-image.test-support.js";

function provisioningDiagnostic(
  outcome: { kind: "lease" } | { kind: "error"; error: unknown },
  calls: readonly { argv: string[] }[],
): string {
  const bounded = (value: string) =>
    redactToolPayloadText(value).replace(/\s+/gu, " ").slice(0, 240);
  const summarize = (value: unknown) => {
    if (!(value instanceof Error)) {
      return { name: typeof value };
    }
    return {
      name: bounded(value.name),
      message: bounded(value.message),
      code: "code" in value && typeof value.code === "string" ? bounded(value.code) : undefined,
    };
  };
  const error = outcome.kind === "error" ? outcome.error : undefined;
  const actions = new Set([
    "config",
    "warmup",
    "inspect",
    "status",
    "run",
    "stop",
    "heartbeat",
    "checkpoint",
  ]);
  const checkpointActions = new Set(["create", "inspect", "fork", "delete"]);
  return JSON.stringify({
    outcome: outcome.kind,
    error: error === undefined ? undefined : summarize(error),
    cause: error instanceof Error && error.cause !== undefined ? summarize(error.cause) : undefined,
    // Never log argv, scripts, options, or environment values. Only known action names.
    actions: calls.slice(0, 16).map(({ argv }) => {
      const action = argv[1];
      if (action === "checkpoint") {
        return checkpointActions.has(argv[2] ?? "") ? `checkpoint ${argv[2]}` : "checkpoint";
      }
      return action && actions.has(action) ? action : "other";
    }),
  });
}

describe("provider invocation behavioral differential", () => {
  it.each([false, true])(
    "settles enrollment setup with independent cleanup (revoked=%s)",
    async (revoked) => {
      const physical = new AbortController();
      const closed = new Error("fixture invocation closed during enrollment");
      let current = true;
      let captured = false;
      let enrollmentCommands = 0;
      const { options, observe } = createProjectOptions([], physical, {
        key: "a".repeat(64),
        cacheKey: "b".repeat(64),
        purpose: "session",
        demandAtMs: Date.now(),
      });
      const { provider, calls } = createWarmProvider((call) => {
        observe(call);
        captured ||= call.argv[1] === "checkpoint" && call.argv[2] === "create";
        if (
          captured &&
          call.argv[1] === "run" &&
          call.options.input?.toString().includes("CRABBOX_NODE_ENROLLMENT_SCRIPT")
        ) {
          enrollmentCommands += 1;
          current = !revoked;
        }
        return undefined;
      });
      const operationId = "baseline-enrollment-cleanup";
      const leaseId = operationLeaseId(operationId);
      // An inferred variable is structurally valid on the legacy parent too. The
      // callback is a real revocable test owner, not a production compatibility shim.
      const provisionOptions = {
        ...options,
        signal: physical.signal,
        assertCurrent: () => {
          if (!current) {
            throw closed;
          }
        },
      };
      const outcome = await provider.provision(PROFILE, operationId, provisionOptions).then(
        (lease) => ({ kind: "lease" as const, lease }),
        (error: unknown) => ({ kind: "error" as const, error }),
      );
      const diagnostic = provisioningDiagnostic(outcome, calls);
      expect(captured, diagnostic).toBe(true);
      expect(enrollmentCommands).toBe(1);
      expect(physical.signal.aborted).toBe(false);
      if (!revoked) {
        expect(outcome).toMatchObject({
          kind: "lease",
          lease: { leaseId, node: { deviceId: "project-node" } },
        });
        return;
      }
      // Observe provider dispatch and persisted custody, not callback/property presence.
      expect
        .soft(
          calls
            .filter(({ argv }) => argv[1] === "stop")
            .map(({ argv }) => argv[argv.indexOf("--id") + 1]),
        )
        .toEqual([leaseId]);
      expect
        .soft(
          calls
            .filter(({ argv }) => argv[1] === "checkpoint" && argv[2] === "delete")
            .map(({ argv }) => argv[3]),
        )
        .toEqual([CHECKPOINT_ID]);
      expect.soft(openWarmImageStore().entries()).toEqual([]);
      expect.soft(calls.some(({ argv }) => argv[1] === "heartbeat")).toBe(false);
      expect(outcome).toMatchObject({
        kind: "error",
        error: { code: "cleanup_complete", leaseId, provisionError: closed },
      });
    },
  );

  it.each([false, true])(
    "does not dispatch enrollment after profile setup loses authority (revoked=%s)",
    async (revoked) => {
      const physical = new AbortController();
      const closed = new Error("fixture invocation closed after profile setup");
      let current = true;
      let setupObserved = false;
      const { options } = createProjectOptions([], physical);
      const { provider, calls } = createWarmProvider((call) => {
        if (call.argv[1] === "run" && call.options.input?.toString() === "fixture-profile-setup") {
          setupObserved = true;
          current = !revoked;
        }
        return undefined;
      });
      const provisionOptions = {
        ...options,
        project: undefined,
        signal: physical.signal,
        assertCurrent: () => {
          if (!current) {
            throw closed;
          }
        },
      };
      const operationId = "baseline-profile-setup";
      const leaseId = operationLeaseId(operationId);
      const outcome = await provider
        .provision(
          { ...PROFILE, warmImage: false, setup: "fixture-profile-setup" },
          operationId,
          provisionOptions,
        )
        .then(
          (lease) => ({ kind: "lease" as const, lease }),
          (error: unknown) => ({ kind: "error" as const, error }),
        );
      const diagnostic = provisioningDiagnostic(outcome, calls);
      expect(setupObserved, diagnostic).toBe(true);
      expect(physical.signal.aborted).toBe(false);
      if (!revoked) {
        expect(outcome).toMatchObject({ kind: "lease", lease: { leaseId } });
        expect(options.beginNodeEnrollment).toHaveBeenCalledOnce();
        return;
      }
      expect.soft(options.beginNodeEnrollment).not.toHaveBeenCalled();
      expect.soft(calls.filter(({ argv }) => argv[1] === "run")).toHaveLength(1);
      expect
        .soft(
          calls
            .filter(({ argv }) => argv[1] === "stop")
            .map(({ argv }) => argv[argv.indexOf("--id") + 1]),
        )
        .toEqual([leaseId]);
      expect(outcome).toMatchObject({
        kind: "error",
        error: { code: "cleanup_complete", leaseId, provisionError: closed },
      });
    },
  );
});
