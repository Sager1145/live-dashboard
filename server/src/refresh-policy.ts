import type { Bundle } from "./contracts.js";

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
