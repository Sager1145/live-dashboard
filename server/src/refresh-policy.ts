import type { Bundle } from "./contracts.js";
import { isArchived, scanWindow } from "./update-window.js";

/** Targets never override the origin's independently enforced request/byte budget. */
export function refreshIntervalSeconds(
  bundles: Bundle[],
  adapterID: string | null,
  policy: Record<string, unknown>,
  now = Date.now(),
): number {
  const explicit = Number(policy.refreshIntervalSeconds);
  if (Number.isFinite(explicit) && explicit > 0)
    return Math.max(60, Math.min(604800, explicit));
  if (!bundles.length || /index|news/.test(adapterID ?? "")) return 21600;
  let closest = Infinity;
  let active = false;
  let undatedShipping = false;
  for (const b of bundles) {
    for (const p of b.performances) {
      // Date-only facts inform scheduling, but never acquire a fabricated public start time.
      const at = Date.parse(p.startAt ?? p.localDate ?? "");
      if (at >= now) closest = Math.min(closest, at - now);
    }
    for (const r of [
      ...b.ticketRounds,
      ...b.goodsCampaigns,
      ...b.streamOffers,
    ]) {
      if (r.status !== "confirmed" || r.scope.kind !== "performances") continue;
      const start =
        "applyStartAt" in r
          ? r.applyStartAt
          : "salesStartAt" in r
            ? r.salesStartAt
            : null;
      const end =
        "applyEndAt" in r
          ? r.applyEndAt
          : "salesEndAt" in r
            ? r.salesEndAt
            : null;
      for (const value of [
        start,
        end,
        "archiveAvailableUntil" in r ? r.archiveAvailableUntil : null,
      ]) {
        const at = Date.parse(value ?? "");
        if (at >= now) closest = Math.min(closest, at - now);
      }
      if (end && Date.parse(end) >= now && (!start || Date.parse(start) <= now))
        active = true;
      if ("shippingNote" in r && r.shippingNote) undatedShipping = true;
    }
  }
  if (closest <= 72 * 3600000) return 3600;
  if (active) return 7200;
  if (Number.isFinite(closest) || undatedShipping) return 86400;
  return 604800;
}

/** Japan civil date. The server window does not follow a phone timezone. */
export function japanCalendarDate(now: Date): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "Asia/Tokyo",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(now);
  const pick = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${pick("year")}-${pick("month")}-${pick("day")}`;
}

/** Inclusive start of the server scan window: one Japan calendar month back. */
export function serverScanCutoff(now = new Date()): string {
  return scanWindow(japanCalendarDate(now), "Asia/Tokyo").from;
}

export interface ScanPerformance {
  localDate?: string | null;
}

/**
 * Archived only when every performance date is known and the last one is
 * strictly before the Japan scan window. Unknown dates stay in the window.
 */
export function tourIsArchived(
  performances: readonly ScanPerformance[] | null | undefined,
  now = new Date(),
): boolean {
  if (!performances?.length) return false;
  const cutoff = serverScanCutoff(now);
  return performances.every((performance) =>
    isArchived(performance?.localDate ?? null, cutoff),
  );
}

export function bundlesInServerScanWindow(
  bundles: readonly { performances?: readonly ScanPerformance[] | null }[],
  now = new Date(),
): boolean {
  if (!bundles.length) return true;
  return bundles.some((bundle) => !tourIsArchived(bundle.performances, now));
}
