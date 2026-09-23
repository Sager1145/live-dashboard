import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { parseBundle } from "../src/contracts.js";
import { refreshIntervalSeconds } from "../src/refresh-policy.js";
import { testDB, seededBundle } from "./support.js";
import { scheduleSources } from "../src/ingestion-worker.js";

test("refresh targets distinguish discovery, near dates, far dates and history without overriding budgets", async () => {
  const b = parseBundle(
    JSON.parse(await readFile("../fixtures/contracts/bundle-v1.json", "utf8")),
  );
  b.ticketRounds = [];
  b.goodsCampaigns = [];
  b.streamOffers = [];
  b.performances.forEach((p) => {
    p.localDate = "2027-01-02";
    p.startAt = null;
    p.doorsAt = null;
  });
  assert.equal(
    refreshIntervalSeconds(
      [b],
      "detail",
      {},
      Date.parse("2027-01-01T00:00:00Z"),
    ),
    3600,
  );
  assert.equal(
    refreshIntervalSeconds(
      [b],
      "index",
      {},
      Date.parse("2027-01-01T00:00:00Z"),
    ),
    21600,
  );
  assert.equal(
    refreshIntervalSeconds(
      [b],
      "detail",
      {},
      Date.parse("2026-10-01T00:00:00Z"),
    ),
    86400,
  );
  assert.equal(
    refreshIntervalSeconds(
      [b],
      "detail",
      {},
      Date.parse("2027-02-01T00:00:00Z"),
    ),
    604800,
  );
  assert.equal(
    refreshIntervalSeconds([b], "detail", { refreshIntervalSeconds: 172800 }),
    172800,
  );
});

test("scheduler gates approval and deduplicates a due document", async () => {
  const db = await testDB();
  try {
    await seededBundle(db);
    assert.equal(await scheduleSources(db), 0);
    await db.query("UPDATE source_origins SET policy=$1", [
      JSON.stringify({
        enabled: true,
        reviewStatus: "approved",
        refreshIntervalSeconds: 7200,
      }),
    ]);
    await db.query("UPDATE source_documents SET enabled=true");
    assert.equal(await scheduleSources(db), 1);
    assert.equal(await scheduleSources(db), 0);
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM jobs")).rows[0].n,
      1,
    );
  } finally {
    await db.close();
  }
});
