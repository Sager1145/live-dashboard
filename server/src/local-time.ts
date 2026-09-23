import { DomainError } from "./contracts.js";

/** Convert an explicitly published wall time; reject nonexistent or ambiguous DST times. */
export function officialInstant(
  date: string,
  clock: string | null | undefined,
  timeZone: string,
): string | null {
  if (!clock) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !/^\d{2}:\d{2}$/.test(clock))
    throw new DomainError(422, "Invalid official local time");
  let [hour, minute] = clock.split(":").map(Number) as [number, number];
  let day = new Date(`${date}T00:00:00Z`);
  if (
    !Number.isFinite(day.getTime()) ||
    day.toISOString().slice(0, 10) !== date
  )
    throw new DomainError(422, "Invalid official calendar date");
  if (hour === 24 && minute === 0) {
    day.setUTCDate(day.getUTCDate() + 1);
    hour = 0;
  }
  if (hour > 23 || minute > 59)
    throw new DomainError(422, "Invalid official clock");
  const wall = day.getTime() + hour * 3600000 + minute * 60000;
  const formatter = new Intl.DateTimeFormat("en-GB", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  });
  const wallValue = (at: number) => {
    const p = Object.fromEntries(
      formatter.formatToParts(new Date(at)).map((v) => [v.type, v.value]),
    );
    return Date.UTC(
      Number(p.year),
      Number(p.month) - 1,
      Number(p.day),
      Number(p.hour),
      Number(p.minute),
    );
  };
  const offsets = new Set(
    [-86400000, 0, 86400000].map(
      (delta) => wallValue(wall + delta) - (wall + delta),
    ),
  );
  const matches = [...offsets]
    .map((offset) => wall - offset)
    .filter((at) => wallValue(at) === wall);
  if (matches.length !== 1)
    throw new DomainError(
      422,
      "Ambiguous or nonexistent official local time; explicit offset review required",
    );
  return new Date(matches[0]!).toISOString();
}
