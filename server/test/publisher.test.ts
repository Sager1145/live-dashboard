import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { seededBundle, testDB } from "./support.js";
import {
  createReview,
  publishReview,
  withdrawEvent,
} from "../src/publisher.js";
import { parseBundle } from "../src/contracts.js";
import { claim, complete, enqueue, fail } from "../src/queue.js";

test("publish is atomic, duplicate business facts do not publish, stale reviews cannot overwrite", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const r = await createReview(db, b, 0);
    await publishReview(db, r.id, "tester", "Verified test evidence");
    assert.equal(
      (await db.query("SELECT count(*) AS count FROM catalog_changes")).rows[0]
        .count,
      1,
    );
    await publishReview(db, r.id, "tester", "Idempotent retry");
    assert.equal(
      (await db.query("SELECT count(*) AS count FROM outbox_events")).rows[0]
        .count,
      1,
    );
    const same = await createReview(
      db,
      { ...b, publishedAt: "2027-01-02T00:00:00Z" },
      1,
    );
    assert.equal(
      (await publishReview(db, same.id, "tester", "Recheck")).unchanged,
      true,
    );
    const next = structuredClone(b);
    next.event.officialTitle = "Official correction";
    const first = await createReview(db, next, 1),
      stale = await createReview(db, next, 1);
    await publishReview(db, first.id, "tester", "Correction");
    await assert.rejects(
      publishReview(db, stale.id, "tester", "Stale"),
      /Stale base/,
    );
    assert.equal(
      (await db.query("SELECT value FROM catalog_clock")).rows[0].value,
      2,
    );
    const rollback = await createReview(db, b, 2);
    await publishReview(
      db,
      rollback.id,
      "tester",
      "Restore reviewed prior version",
    );
    assert.equal(
      (await db.query("SELECT revision FROM events")).rows[0].revision,
      3,
    );
  } finally {
    await db.close();
  }
});

test("missing evidence and snapshots roll back without changing public data", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    b.evidence = [];
    const r = await createReview(db, b, 0);
    await assert.rejects(
      publishReview(db, r.id, "tester", "Attempt"),
      /Missing confirmed evidence/,
    );
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM events")).rows[0].n,
      0,
    );
    assert.equal(
      (await db.query("SELECT value FROM catalog_clock")).rows[0].value,
      0,
    );
  } finally {
    await db.close();
  }
});

test("scope does not grow when a new performance is added; cross-day offer rejected", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const tier = randomUUID(),
      round = randomUUID();
    const scope = {
      kind: "performances" as const,
      performanceIDs: [b.performances[0]!.id],
    };
    const draft = parseBundle({
      ...b,
      ticketTiers: [
        {
          id: tier,
          eventID: b.event.id,
          name: "normal",
          priceKind: "full",
          priceJPY: 10000,
        },
      ],
      ticketRounds: [
        {
          id: round,
          eventID: b.event.id,
          officialName: "DAY1 only",
          kind: "lottery",
          scope,
          status: "confirmed",
        },
      ],
    });
    assert.throws(
      () =>
        parseBundle({
          ...draft,
          ticketOffers: [
            {
              id: randomUUID(),
              tierID: tier,
              roundID: round,
              performanceIDs: [b.performances[1]!.id],
            },
          ],
        }),
      /exceeds/,
    );
    assert.throws(() =>
      parseBundle({
        ...draft,
        ticketRounds: [
          { ...draft.ticketRounds[0], scope: { kind: "wholeEvent" } },
        ],
      }),
    );
    assert.equal(draft.ticketRounds[0]!.scope.kind, "performances");
  } finally {
    await db.close();
  }
});

test("queue deduplication, expiring leases and fencing prevent stale completion", async () => {
  const db = await testDB();
  try {
    await enqueue(db, "fetch", { url: "https://example.org" }, "one");
    await enqueue(db, "fetch", {}, "one");
    const first = await claim(db, "fetch");
    assert.ok(first);
    assert.equal(await claim(db, "fetch"), null);
    await db.query("UPDATE jobs SET lease_until=now()-interval '1 second'");
    const second = await claim(db, "fetch");
    assert.ok(second);
    assert.equal(await complete(db, first.id, first.fencing_token), false);
    assert.equal(await complete(db, second.id, second.fencing_token), true);
    assert.equal(await complete(db, second.id, second.fencing_token), false);
  } finally {
    await db.close();
  }
});

test("withdrawal writes tombstone instead of silently removing catalog identity", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const r = await createReview(db, b, 0);
    await publishReview(db, r.id, "tester", "Initial");
    await withdrawEvent(db, b.event.id, 1, "tester", "Confirmed removal");
    const changes = (
      await db.query("SELECT kind FROM catalog_changes ORDER BY sequence")
    ).rows;
    assert.deepEqual(
      changes.map((r) => r.kind),
      ["upsert", "delete"],
    );
  } finally {
    await db.close();
  }
});
