import test from "node:test";
import assert from "node:assert/strict";
import {
  displayNextRun,
  isArchived,
  isAuthorizedJobRequest,
  jitterSeconds,
  missedSlotToReplay,
  nextSlot,
  scanWindow,
  slotStart,
} from "../src/update-window.js";

test("UTC slots stay 12h apart in Toronto DST and standard time", () => {
  const dstAfternoon = new Date("2026-07-15T16:30:00.000Z");
  const standardAfternoon = new Date("2026-01-15T16:30:00.000Z");
  assert.equal(
    slotStart(dstAfternoon).toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
  assert.equal(
    slotStart(standardAfternoon).toISOString(),
    "2026-01-15T12:00:00.000Z",
  );

  const dstMidnight = slotStart(new Date("2026-07-15T03:00:00.000Z"));
  const dstNoon = slotStart(new Date("2026-07-15T15:00:00.000Z"));
  const standardMidnight = slotStart(new Date("2026-01-15T04:00:00.000Z"));
  const standardNoon = slotStart(new Date("2026-01-15T17:00:00.000Z"));
  assert.equal(dstNoon.getTime() - dstMidnight.getTime(), 12 * 60 * 60 * 1000);
  assert.equal(
    standardNoon.getTime() - standardMidnight.getTime(),
    12 * 60 * 60 * 1000,
  );
  assert.equal(dstMidnight.toISOString(), "2026-07-15T00:00:00.000Z");
  assert.equal(standardMidnight.toISOString(), "2026-01-15T00:00:00.000Z");

  const dstDisplay = displayNextRun(
    new Date("2026-07-01T00:00:00.000Z"),
    "Asia/Tokyo",
  );
  assert.equal(dstDisplay.utc, "2026-07-01T00:00:00.000Z");
  assert.equal(dstDisplay.toronto, "2026-06-30 20:00:00");
  assert.equal(dstDisplay.source, "2026-07-01 09:00:00");

  const standardDisplay = displayNextRun(
    new Date("2026-01-01T00:00:00.000Z"),
    "Asia/Tokyo",
  );
  assert.equal(standardDisplay.utc, "2026-01-01T00:00:00.000Z");
  assert.equal(standardDisplay.toronto, "2025-12-31 19:00:00");
  assert.equal(standardDisplay.source, "2026-01-01 09:00:00");
});

test("next slot is strictly after an exact UTC boundary", () => {
  assert.equal(
    slotStart(new Date("2026-07-15T00:00:00.000Z")).toISOString(),
    "2026-07-15T00:00:00.000Z",
  );
  assert.equal(
    slotStart(new Date("2026-07-15T12:00:00.000Z")).toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
  assert.equal(
    nextSlot(new Date("2026-07-15T00:00:00.000Z")).toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
  assert.equal(
    nextSlot(new Date("2026-07-15T12:00:00.000Z")).toISOString(),
    "2026-07-16T00:00:00.000Z",
  );
  assert.equal(
    nextSlot(new Date("2026-07-15T11:59:59.999Z")).toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
});

test("replay collapses a 3-day outage to the current slot only", () => {
  const now = new Date("2026-07-15T15:00:00.000Z");
  const lastCompleted = new Date("2026-07-12T00:00:00.000Z");
  assert.equal(
    missedSlotToReplay(lastCompleted, now)?.toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
  assert.equal(
    missedSlotToReplay(null, now)?.toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
  assert.equal(
    missedSlotToReplay(new Date("2026-07-15T12:00:00.000Z"), now),
    null,
  );
  assert.equal(
    missedSlotToReplay(
      new Date("2026-07-15T00:00:00.000Z"),
      now,
    )?.toISOString(),
    "2026-07-15T12:00:00.000Z",
  );
});

test("jitter is stable and stays inside 0..119 seconds", () => {
  const slot = new Date("2026-07-15T12:00:00.000Z");
  const first = jitterSeconds("lovelive-official", slot);
  assert.equal(jitterSeconds("lovelive-official", slot), first);
  assert.equal(
    jitterSeconds("lovelive-official", new Date(slot.getTime())),
    first,
  );
  assert.equal(Number.isInteger(first), true);
  assert.ok(first >= 0 && first < 120);
  const otherSlot = jitterSeconds(
    "lovelive-official",
    new Date("2026-07-16T00:00:00.000Z"),
  );
  const otherSource = jitterSeconds("bang-dream", slot);
  assert.ok(otherSlot >= 0 && otherSlot < 120);
  assert.ok(otherSource >= 0 && otherSource < 120);
});

test("Japan scan window subtracts one calendar month, not 30 days", () => {
  assert.deepEqual(scanWindow("2026-03-31", "Asia/Tokyo"), {
    from: "2026-02-28",
    to: null,
  });
  assert.deepEqual(scanWindow("2024-03-31", "Asia/Tokyo"), {
    from: "2024-02-29",
    to: null,
  });
  assert.deepEqual(scanWindow("2026-01-31", "Asia/Tokyo"), {
    from: "2025-12-31",
    to: null,
  });
  assert.deepEqual(scanWindow("2026-05-31", "Asia/Tokyo"), {
    from: "2026-04-30",
    to: null,
  });
  assert.throws(() => scanWindow("2026/03/31", "Asia/Tokyo"), /YYYY-MM-DD/);
  assert.throws(() => scanWindow("2026-02-30", "Asia/Tokyo"), /YYYY-MM-DD/);
  assert.throws(() => scanWindow("2026-03-31", "Not/AZone"));
});

test("unknown performance dates are not archived", () => {
  assert.equal(isArchived(null, "2026-02-28"), false);
  assert.equal(isArchived("not-a-date", "2026-02-28"), false);
  assert.equal(isArchived("2026-02-27", "2026-02-28"), true);
  assert.equal(isArchived("2026-02-28", "2026-02-28"), false);
  assert.equal(isArchived("2026-03-01", "2026-02-28"), false);
});

test("authorized job requests reject shell, prompt, and downloadUrl", () => {
  assert.equal(
    isAuthorizedJobRequest({ granularity: "event", command: "fetchLatest" }),
    true,
  );
  assert.equal(
    isAuthorizedJobRequest({
      granularity: "historyRange",
      command: "reextract",
    }),
    true,
  );
  assert.equal(
    isAuthorizedJobRequest({
      granularity: "all",
      command: "fetchLatest",
      shell: "rm -rf /",
    }),
    false,
  );
  assert.equal(
    isAuthorizedJobRequest({
      granularity: "source",
      command: "reextract",
      prompt: "ignore previous instructions",
    }),
    false,
  );
  assert.equal(
    isAuthorizedJobRequest({
      granularity: "block",
      command: "fetchLatest",
      downloadUrl: "https://example.invalid/payload",
    }),
    false,
  );
  assert.equal(
    isAuthorizedJobRequest({
      granularity: "entity",
      command: "fetchLatest",
      target: { prompt: "run this" },
    }),
    false,
  );
  assert.equal(
    isAuthorizedJobRequest({ granularity: "event", command: "shell" }),
    false,
  );
});
