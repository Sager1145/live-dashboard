import test from "node:test";
import assert from "node:assert/strict";
import { officialInstant } from "../src/local-time.js";
test("official timezone, date precision, 24:00, invalid dates and DST ambiguity", () => {
  assert.equal(
    officialInstant("2026-10-10", "18:00", "Asia/Tokyo"),
    "2026-10-10T09:00:00.000Z",
  );
  assert.equal(
    officialInstant("2026-10-10", "18:00", "Asia/Taipei"),
    "2026-10-10T10:00:00.000Z",
  );
  assert.equal(
    officialInstant("2026-12-31", "24:00", "Asia/Tokyo"),
    "2026-12-31T15:00:00.000Z",
  );
  assert.equal(officialInstant("2026-10-10", null, "Asia/Tokyo"), null);
  assert.throws(
    () => officialInstant("2026-02-30", "18:00", "Asia/Tokyo"),
    /calendar/,
  );
  assert.throws(
    () => officialInstant("2026-03-08", "02:30", "America/Toronto"),
    /nonexistent/,
  );
  assert.throws(
    () => officialInstant("2026-11-01", "01:30", "America/Toronto"),
    /Ambiguous/,
  );
});
