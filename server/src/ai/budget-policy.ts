import type { ProviderId } from "./provider.js";

export type BudgetPauseCode = "AUTH_REQUIRED" | "QUOTA_EXHAUSTED";

export type BudgetDecision =
  | { ok: true }
  | {
      ok: false;
      code: BudgetPauseCode | "RATE_LIMITED";
      message: string;
      quotaRemaining: "unknown";
      retryAfterMs: number | null;
    };

/**
 * In-process cap. Default one in-flight run per provider. No Redis.
 * Auth and quota pauses reject later runs until cleared by the owner.
 */
export class BudgetPolicy {
  private readonly maxInFlight: number;
  private readonly inFlight = new Map<ProviderId, number>();
  private readonly paused = new Map<ProviderId, BudgetPauseCode>();

  constructor(options?: { maxInFlight?: number }) {
    const requested = options?.maxInFlight ?? 1;
    if (!Number.isInteger(requested) || requested < 1) {
      throw new Error("maxInFlight must be a positive integer");
    }
    this.maxInFlight = requested;
  }

  tryAcquire(providerId: ProviderId): BudgetDecision {
    const pause = this.paused.get(providerId);
    if (pause) {
      return {
        ok: false,
        code: pause,
        message: `${providerId} is paused after ${pause}`,
        quotaRemaining: "unknown",
        retryAfterMs: null,
      };
    }
    const current = this.inFlight.get(providerId) ?? 0;
    if (current >= this.maxInFlight) {
      return {
        ok: false,
        code: "RATE_LIMITED",
        message: `${providerId} is at its in-flight limit`,
        quotaRemaining: "unknown",
        retryAfterMs: null,
      };
    }
    this.inFlight.set(providerId, current + 1);
    return { ok: true };
  }

  release(providerId: ProviderId): void {
    const current = this.inFlight.get(providerId) ?? 0;
    this.inFlight.set(providerId, Math.max(0, current - 1));
  }

  observe(providerId: ProviderId, code: string): void {
    if (code === "AUTH_REQUIRED" || code === "QUOTA_EXHAUSTED") {
      this.paused.set(providerId, code);
    }
  }

  isPaused(providerId: ProviderId): boolean {
    return this.paused.has(providerId);
  }

  resume(providerId: ProviderId): void {
    this.paused.delete(providerId);
  }
}
