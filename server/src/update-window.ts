import { createHash } from "node:crypto";

const HALF_DAY_MS = 12 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const JITTER_SPAN_SECONDS = 120;
const YMD = /^(\d{4})-(\d{2})-(\d{2})$/;
const FORBIDDEN_JOB_FIELDS = ["downloadUrl", "shell", "prompt"] as const;

export type ManualGranularity =
  | "all"
  | "source"
  | "event"
  | "block"
  | "entity"
  | "historyRange";

export type ManualCommand = "fetchLatest" | "reextract";

export interface AuthorizedJobRequest {
  granularity: ManualGranularity;
  command: ManualCommand;
}

const GRANULARITIES = new Set<string>([
  "all",
  "source",
  "event",
  "block",
  "entity",
  "historyRange",
]);

const COMMANDS = new Set<string>(["fetchLatest", "reextract"]);

/** Floor to the UTC 00:00 or 12:00 slot that contains `now`. Gap is always 12h. */
export function slotStart(now: Date): Date {
  const t = now.getTime();
  if (!Number.isFinite(t)) throw new Error("Invalid date");
  const day = Math.floor(t / DAY_MS) * DAY_MS;
  const offset = t - day >= HALF_DAY_MS ? HALF_DAY_MS : 0;
  return new Date(day + offset);
}

/** The following 00:00Z or 12:00Z strictly after `now`, including exact boundaries. */
export function nextSlot(now: Date): Date {
  return new Date(slotStart(now).getTime() + HALF_DAY_MS);
}

function formatInZone(slot: Date, timeZone: string): string {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(slot)
      .map((part) => [part.type, part.value]),
  );
  return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}:${parts.second}`;
}

/** Wall times for the admin page. Zones are explicit; the host zone is never used. */
export function displayNextRun(
  slot: Date,
  sourceTimeZone: string,
): { utc: string; toronto: string; source: string } {
  if (!Number.isFinite(slot.getTime())) throw new Error("Invalid date");
  return {
    utc: slot.toISOString(),
    toronto: formatInZone(slot, "America/Toronto"),
    source: formatInZone(slot, sourceTimeZone),
  };
}

/**
 * After downtime, replay only the current unfinished slot.
 * A null last completion means this slot has never been recorded.
 */
export function missedSlotToReplay(
  lastCompletedSlot: Date | null,
  now: Date,
): Date | null {
  const current = slotStart(now);
  if (lastCompletedSlot === null) return current;
  const completed = lastCompletedSlot.getTime();
  if (!Number.isFinite(completed)) throw new Error("Invalid date");
  if (completed >= current.getTime()) return null;
  return current;
}

/** Deterministic 0..119s stagger from source id and slot, not Math.random. */
export function jitterSeconds(sourceId: string, slot: Date): number {
  const digest = createHash("sha256")
    .update(`${sourceId}\0${slot.toISOString()}`)
    .digest();
  return digest.readUInt32BE(0) % JITTER_SPAN_SECONDS;
}

function parseYmd(
  value: string,
): { year: number; month: number; day: number } | null {
  const match = YMD.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const probed = new Date(Date.UTC(year, month - 1, day));
  if (
    probed.getUTCFullYear() !== year ||
    probed.getUTCMonth() !== month - 1 ||
    probed.getUTCDate() !== day
  )
    return null;
  return { year, month, day };
}

function pad(value: number, width: number): string {
  return String(value).padStart(width, "0");
}

/** Previous calendar month, clamping to the last real day (Mar 31 → Feb 28/29). */
function subtractOneCalendarMonth(
  year: number,
  month: number,
  day: number,
): string {
  let targetYear = year;
  let targetMonth = month - 1;
  if (targetMonth < 1) {
    targetMonth = 12;
    targetYear -= 1;
  }
  const lastDay = new Date(Date.UTC(targetYear, targetMonth, 0)).getUTCDate();
  return `${pad(targetYear, 4)}-${pad(targetMonth, 2)}-${pad(Math.min(day, lastDay), 2)}`;
}

/**
 * Source scan window: one calendar month before `today` through all future dates.
 * `today` is already the source calendar date (Japan for Japanese sources).
 */
export function scanWindow(
  today: string,
  timeZone: string,
): { from: string; to: null } {
  const parsed = parseYmd(today);
  if (!parsed) throw new Error("today must be YYYY-MM-DD");
  // Reject unknown zones here so formatting never falls back to the host zone.
  new Intl.DateTimeFormat("en-CA", { timeZone }).format(0);
  return {
    from: subtractOneCalendarMonth(parsed.year, parsed.month, parsed.day),
    to: null,
  };
}

/**
 * Archived only when the last performance is a real date strictly before the window.
 * Null or unparseable dates stay in the check set.
 */
export function isArchived(
  lastPerformanceDate: string | null,
  windowFrom: string,
): boolean {
  if (lastPerformanceDate === null) return false;
  const last = parseYmd(lastPerformanceDate);
  const from = parseYmd(windowFrom);
  if (!last || !from) return false;
  return lastPerformanceDate < windowFrom;
}

function containsForbiddenField(value: unknown, seen: Set<object>): boolean {
  if (value === null || typeof value !== "object") return false;
  if (seen.has(value)) return false;
  seen.add(value);
  for (const key of FORBIDDEN_JOB_FIELDS) {
    if (key in value) return true;
  }
  for (const child of Object.values(value)) {
    if (containsForbiddenField(child, seen)) return true;
  }
  return false;
}

/** Client job bodies may name a granularity and command, never a URL, shell, or prompt. */
export function isAuthorizedJobRequest(
  request: unknown,
): request is AuthorizedJobRequest {
  if (request === null || typeof request !== "object") return false;
  if (containsForbiddenField(request, new Set())) return false;
  const record = request as Record<string, unknown>;
  return (
    typeof record.granularity === "string" &&
    GRANULARITIES.has(record.granularity) &&
    typeof record.command === "string" &&
    COMMANDS.has(record.command)
  );
}
