import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { seededBundle, testDB } from "./support.js";
import {
  autoPublish,
  createReview,
  publishReview,
  retainConfirmedFields,
  withdrawEvent,
} from "../src/publisher.js";
import { parseBundle, type Bundle } from "../src/contracts.js";
import {
  createValidationReceipt,
  type ValidationReceipt,
} from "../src/validation-receipt.js";
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

function receiptFor(
  bundle: Bundle,
  actor: ValidationReceipt["actor"] = "machine",
  readyAssetIDs: string[] = [],
  extra: Partial<ValidationReceipt> = {},
) {
  const snapshotIDs = [...new Set(bundle.evidence.map((item) => item.snapshotID))];
  return createValidationReceipt({
    policyVersion: "2026-09-24",
    snapshotHashes: snapshotIDs.map((id) => ({ id, contentHash: "testhash" })),
    blockHashes: [],
    taskHash: "task",
    outputHash: "output",
    fieldChecks: [],
    scopeChecks: [],
    readyAssetIDs,
    actor,
    ...extra,
  });
}

function evidenceFor(bundle: Bundle, recordID: string, field: string) {
  return {
    ...bundle.evidence[0]!,
    id: randomUUID(),
    recordID,
    field,
    verification: "confirmed" as const,
  };
}

test("source fetch failure does not clear previously confirmed fields", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const review = await createReview(db, b, 0);
    await publishReview(db, review.id, "tester", "Initial");
    const failed = structuredClone(b);
    failed.sourceHealth = "fetch_failed";
    for (const performance of failed.performances) performance.localDate = null;
    const retained = retainConfirmedFields(b, failed);
    assert.equal(retained.performances[0]!.localDate, b.performances[0]!.localDate);
    assert.equal(retained.performances[1]!.localDate, b.performances[1]!.localDate);
    const again = await createReview(db, failed, 1);
    const result = await publishReview(db, again.id, "tester", "Fetch failed");
    assert.equal(result.unchanged, true);
    const stored = (await db.query("SELECT bundle FROM events")).rows[0].bundle;
    assert.equal(stored.performances[0].localDate, b.performances[0]!.localDate);
    assert.equal(stored.performances[1].localDate, b.performances[1]!.localDate);
    assert.equal(
      (await db.query("SELECT value FROM catalog_clock")).rows[0].value,
      1,
    );
    const auto = await autoPublish(db, failed, 1, receiptFor(failed));
    assert.equal(auto.status, "published");
    if (auto.status === "published") assert.equal(auto.unchanged, true);
    const after = (await db.query("SELECT bundle FROM events")).rows[0].bundle;
    assert.equal(after.performances[0].localDate, b.performances[0]!.localDate);
  } finally {
    await db.close();
  }
});

test("unconfirmed scope stays in review and is not rewritten to every performance", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const roundID = randomUUID();
    const draft = parseBundle({
      ...b,
      ticketRounds: [
        {
          id: roundID,
          eventID: b.event.id,
          officialName: "General sale",
          kind: "lottery",
          scope: { kind: "unconfirmed" },
          status: "needsReview",
        },
      ],
    });
    const result = await autoPublish(db, draft, 0, receiptFor(draft));
    assert.equal(result.status, "needsReview");
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM events")).rows[0].n,
      0,
    );
    const proposal = (
      await db.query("SELECT proposal FROM review_cases")
    ).rows[0].proposal;
    assert.equal(proposal.ticketRounds[0].scope.kind, "unconfirmed");
    assert.equal(proposal.ticketRounds[0].scope.performanceIDs, undefined);
    assert.notDeepEqual(
      proposal.ticketRounds[0].scope.performanceIDs,
      draft.performances.map((performance) => performance.id),
    );
  } finally {
    await db.close();
  }
});

test("conflicting evidence stays in review without dropping confirmed fields", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const review = await createReview(db, b, 0);
    await publishReview(db, review.id, "tester", "Initial");
    const next = structuredClone(b);
    next.event.officialTitle = "Official correction";
    const venue = next.evidence.find((item) => item.field === "venueName");
    assert.ok(venue);
    venue.verification = "conflict";
    const result = await autoPublish(db, next, 1, receiptFor(next));
    assert.equal(result.status, "needsReview");
    if (result.status === "needsReview")
      assert.ok(result.issues.some((issue) => issue.code === "conflicting_evidence"));
    const stored = (await db.query("SELECT bundle,revision FROM events")).rows[0];
    assert.equal(stored.revision, 1);
    assert.equal(stored.bundle.event.officialTitle, "Synthetic test event");
    const proposal = (
      await db.query(
        "SELECT proposal FROM review_cases WHERE status='pending'",
      )
    ).rows[0].proposal;
    assert.equal(proposal.event.officialTitle, "Official correction");
    assert.equal(
      proposal.evidence.find(
        (item: { field: string }) => item.field === "venueName",
      ).verification,
      "conflict",
    );
  } finally {
    await db.close();
  }
});

test("auto-publish does not bulk-set verification to confirmed", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    for (const evidence of b.evidence) evidence.verification = "needsReview";
    const result = await autoPublish(db, b, 0, receiptFor(b));
    assert.equal(result.status, "needsReview");
    const proposal = (await db.query("SELECT proposal FROM review_cases")).rows[0]
      .proposal;
    assert.ok(
      proposal.evidence.every(
        (item: { verification: string }) => item.verification === "needsReview",
      ),
    );
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM events")).rows[0].n,
      0,
    );
  } finally {
    await db.close();
  }
});

test("new permitted assets publish only when the receipt lists them ready", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const mediaID = randomUUID();
    const performanceID = b.performances[0]!.id;
    const withMedia = (policy: "permitted_cache" | "link_only" | "permitted_remote_display") =>
      parseBundle({
        ...b,
        mediaAssets: [
          {
            id: mediaID,
            eventID: b.event.id,
            scope: { kind: "performances", performanceIDs: [performanceID] },
            kind: "keyVisual",
            originalURL: "https://example.org/kv.png",
            sourceURL: "https://example.org/live",
            version: 1,
            displayPolicy: policy,
          },
        ],
        evidence: [
          ...b.evidence,
          evidenceFor(b, mediaID, "kind"),
          evidenceFor(b, mediaID, "scope"),
        ],
      });
    const blocked = withMedia("permitted_cache");
    const held = await autoPublish(db, blocked, 0, receiptFor(blocked));
    assert.equal(held.status, "needsReview");
    if (held.status === "needsReview")
      assert.ok(held.issues.some((issue) => issue.code === "asset_not_ready"));
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM events")).rows[0].n,
      0,
    );
    const linked = withMedia("link_only");
    const linkResult = await autoPublish(db, linked, 0, receiptFor(linked));
    assert.equal(linkResult.status, "published");
    const remoteID = randomUUID();
    const remote = parseBundle({
      ...linked,
      event: { ...linked.event, officialTitle: "Remote visual" },
      mediaAssets: [
        {
          ...linked.mediaAssets[0]!,
          id: remoteID,
          displayPolicy: "permitted_remote_display" as const,
        },
      ],
      evidence: [
        ...b.evidence,
        evidenceFor(b, remoteID, "kind"),
        evidenceFor(b, remoteID, "scope"),
      ],
    });
    const remoteHeld = await autoPublish(db, remote, 1, receiptFor(remote));
    assert.equal(remoteHeld.status, "needsReview");
    const remoteReady = await autoPublish(
      db,
      remote,
      1,
      receiptFor(remote, "human", [remoteID]),
    );
    assert.equal(remoteReady.status, "published");
    if (remoteReady.status === "published") assert.equal(remoteReady.revision, 2);
    const upgraded = parseBundle({
      ...remote,
      mediaAssets: [
        { ...remote.mediaAssets[0]!, displayPolicy: "permitted_cache" as const },
      ],
    });
    const upgradeHeld = await autoPublish(
      db,
      upgraded,
      2,
      receiptFor(upgraded, "machine", []),
    );
    assert.equal(upgradeHeld.status, "published");
    const retitle = parseBundle({
      ...upgraded,
      event: { ...upgraded.event, officialTitle: "Title only" },
    });
    const again = await autoPublish(
      db,
      retitle,
      3,
      receiptFor(retitle, "machine", []),
    );
    assert.equal(again.status, "published");
    if (again.status === "published") assert.equal(again.revision, 4);
    const reviewers = (
      await db.query(
        "SELECT revision, reviewer FROM event_revisions ORDER BY revision",
      )
    ).rows;
    assert.deepEqual(
      reviewers.map((row) => [row.revision, row.reviewer]),
      [
        [1, "machine"],
        [2, "human"],
        [3, "machine"],
        [4, "machine"],
      ],
    );
  } finally {
    await db.close();
  }
});

test("auto-publish keeps catalog commit order, stale base 409, and business-hash dedupe", async () => {
  const db = await testDB();
  try {
    const b = await seededBundle(db);
    const first = await autoPublish(db, b, 0, receiptFor(b, "machine"));
    assert.equal(first.status, "published");
    const same = await autoPublish(
      db,
      { ...b, publishedAt: "2027-02-02T00:00:00Z" },
      1,
      receiptFor(b),
    );
    assert.equal(same.status, "published");
    if (same.status === "published") assert.equal(same.unchanged, true);
    await assert.rejects(
      autoPublish(db, b, 0, receiptFor(b)),
      /Stale base/,
    );
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM catalog_changes")).rows[0].n,
      1,
    );
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM outbox_events")).rows[0].n,
      1,
    );
    assert.equal(
      (await db.query("SELECT value FROM catalog_clock")).rows[0].value,
      1,
    );
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
