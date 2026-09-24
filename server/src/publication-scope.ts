export type FieldStatus =
  | "evidenced"
  | "officiallyUnannounced"
  | "scopeUnconfirmed"
  | "sourceUnavailable"
  | "contradictory"
  | "notApplicable";

export type ScopeStatement = "event" | "edition" | "stop" | "performances";

export type UnconfirmedScopeReason =
  | "unverified-performance"
  | "no-performances";

/** Published performances scope. `performanceIDs` is non-empty, deduped, and sorted. */
export type PerformancesScope = {
  kind: "performances";
  performanceIDs: string[];
};

/**
 * Diagnostic unconfirmed result. `reason` is internal; v1 `scopeSchema` has no reason field.
 */
export type UnconfirmedScope = {
  kind: "unconfirmed";
  reason: UnconfirmedScopeReason;
};

export type MaterializedScope = PerformancesScope | UnconfirmedScope;

export type LocalClock = {
  localDate: string | null;
  localTime: string | null;
};

const statements = new Set<ScopeStatement>([
  "event",
  "edition",
  "stop",
  "performances",
]);

function sortedUnique(ids: readonly string[]): string[] {
  return [...new Set(ids)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

/**
 * Materialize an internal event/edition/stop/performances claim.
 * `performanceIDs` is the claim's current expansion. This does not widen it to
 * every verified performance. Any unverified id rejects the whole claim.
 */
export function materializeScope(input: {
  statement: ScopeStatement;
  performanceIDs: readonly string[];
  verifiedPerformanceIDs: readonly string[];
}): MaterializedScope {
  if (!statements.has(input.statement))
    throw new Error(`unknown scope statement: ${input.statement}`);
  const verified = new Set(input.verifiedPerformanceIDs);
  if (input.performanceIDs.some((id) => !verified.has(id)))
    return { kind: "unconfirmed", reason: "unverified-performance" };
  if (input.performanceIDs.length === 0)
    return { kind: "unconfirmed", reason: "no-performances" };
  return {
    kind: "performances",
    performanceIDs: sortedUnique(input.performanceIDs),
  };
}

/**
 * Ticket/media scope already published. Keeps only ids still verified.
 * Ids that appear only in `nextVerifiedPerformanceIDs` are not inherited.
 */
export function inheritScope(
  previousPerformanceIDs: readonly string[],
  nextVerifiedPerformanceIDs: readonly string[],
): string[] {
  const next = new Set(nextVerifiedPerformanceIDs);
  const seen = new Set<string>();
  const kept: string[] = [];
  for (const id of previousPerformanceIDs) {
    if (!next.has(id) || seen.has(id)) continue;
    seen.add(id);
    kept.push(id);
  }
  return kept;
}

/** Reject a fabricated midnight. A stated "00:00" is left alone. */
export function assertNoInventedInstant(
  value: LocalClock,
  timeExplicitlyStated: boolean,
): void {
  if (!timeExplicitlyStated && value.localTime === "00:00")
    throw new Error(
      "missing local time must stay null; do not fabricate 00:00",
    );
}

/** Missing or unstated clock stays null. Does not substitute midnight. */
export function explicitLocalTime(
  value: LocalClock,
  timeExplicitlyStated: boolean,
): string | null {
  assertNoInventedInstant(value, timeExplicitlyStated);
  if (!timeExplicitlyStated) return null;
  return value.localTime;
}

export type TicketDeadline = {
  localDate: string;
  localTime: string;
  timeZone: string;
};

function isIanaTimeZone(timeZone: string): boolean {
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone }).format(0);
    return true;
  } catch {
    return false;
  }
}

/**
 * Keep a ticket deadline as a zoned wall time.
 * Requires an explicit IANA zone. Does not read the host zone or convert to an instant.
 */
export function ticketDeadline(input: {
  localDate: string;
  localTime: string;
  timeZone?: string | null;
}): TicketDeadline {
  if (input.timeZone == null || input.timeZone.trim() === "")
    throw new Error("timezone required");
  if (!isIanaTimeZone(input.timeZone)) throw new Error("timezone required");
  return {
    localDate: input.localDate,
    localTime: input.localTime,
    timeZone: input.timeZone,
  };
}
