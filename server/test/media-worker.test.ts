import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import {
  enqueueDiscoveredCandidateMedia,
  runCandidateMediaJob,
  runMediaJob,
  scheduleMedia,
} from "../src/media-worker.js";
import { createReview, publishReview } from "../src/publisher.js";
import { LocalBlobStore, MemoryCandidateStore } from "../src/storage/index.js";
import { seededBundle, testDB } from "./support.js";
import type { DB } from "../src/db.js";

const mediaURL = "https://media.example.test/approved/map.png";
const approvedPolicy = {
  id: "media-test",
  enabled: true,
  reviewStatus: "approved",
  robotsCheckedAt: "2026-09-22T00:00:00Z",
  termsReviewedAt: "2026-09-22T00:00:00Z",
  host: "media.example.test",
  allowedPaths: ["/approved/"],
  contentTypes: ["image/png"],
  minimumIntervalSeconds: 30,
  requestBudget: 100,
  byteBudget: 1_000_000,
};

function png(width: number, height: number): Buffer {
  const value = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(value);
  value.write("IHDR", 12, "ascii");
  value.writeUInt32BE(width, 16);
  value.writeUInt32BE(height, 20);
  return value;
}

async function publishedMedia(
  db: DB,
  displayPolicy: "link_only" | "permitted_cache" = "permitted_cache",
) {
  const bundle = await seededBundle(db);
  const mediaID = randomUUID();
  const seedEvidence = bundle.evidence[0]!;
  bundle.mediaAssets.push({
    id: mediaID,
    eventID: bundle.event.id,
    kind: "eventSeatingMap",
    originalURL: mediaURL,
    thumbnailURL: null,
    sourceURL: seedEvidence.sourceURL,
    version: 1,
    caption: "Synthetic media fixture",
    displayPolicy,
    scope: {
      kind: "performances",
      performanceIDs: [bundle.performances[0]!.id],
    },
  });
  for (const field of ["kind", "scope"])
    bundle.evidence.push({
      ...seedEvidence,
      id: randomUUID(),
      recordID: mediaID,
      field,
      performanceIDs: [bundle.performances[0]!.id],
    });
  const review = await createReview(db, bundle, 0);
  await publishReview(
    db,
    review.id,
    "media-test",
    "Publish synthetic media test asset",
  );
  await db.query(
    "INSERT INTO source_origins(id,origin,policy) VALUES($1,$2,$3)",
    [
      randomUUID(),
      "https://media.example.test",
      JSON.stringify({ ...approvedPolicy, enabled: false }),
    ],
  );
  return { eventID: bundle.event.id, mediaID };
}

test("scheduler requires a published cache-approved asset and an explicitly approved media origin", async () => {
  const db = await testDB();
  try {
    const cached = await publishedMedia(db);
    assert.equal(
      await scheduleMedia(db, { now: new Date("2026-09-22T12:00:00Z") }),
      0,
    );
    await db.query("UPDATE source_origins SET policy=$2 WHERE origin=$1", [
      "https://media.example.test",
      JSON.stringify(approvedPolicy),
    ]);
    assert.equal(
      await scheduleMedia(db, { now: new Date("2026-09-22T12:00:00Z") }),
      1,
    );
    assert.equal(
      await scheduleMedia(db, { now: new Date("2026-09-22T12:00:00Z") }),
      0,
    );
    assert.deepEqual(
      (
        await db.query("SELECT kind,payload FROM jobs WHERE kind='media.fetch'")
      ).rows.map((row) => ({ kind: row.kind, assetID: row.payload.assetID })),
      [{ kind: "media.fetch", assetID: cached.mediaID }],
    );

    // A link-only candidate is never normalized into this scheduler's result set.
    await db.query(
      "UPDATE scoped_records SET data=jsonb_set(data,'{displayPolicy}','\"link_only\"'::jsonb) WHERE id=$1",
      [cached.mediaID],
    );
    await db.query("DELETE FROM jobs WHERE kind='media.fetch'");
    assert.equal(
      await scheduleMedia(db, { now: new Date("2026-09-22T18:00:00Z") }),
      0,
    );
  } finally {
    await db.close();
  }
});

test("worker stores changed bytes privately and creates a review without changing the published asset", async (t) => {
  const db = await testDB();
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-worker-"),
  );
  t.after(async () => {
    await db.close();
    await rm(root, { recursive: true, force: true });
  });
  const { eventID, mediaID } = await publishedMedia(db);
  await db.query("UPDATE source_origins SET policy=$2 WHERE origin=$1", [
    "https://media.example.test",
    JSON.stringify(approvedPolicy),
  ]);
  await scheduleMedia(db);
  let calls = 0;
  const bytes = png(1200, 800);
  const worked = await runMediaJob(db, {
    blobs: new LocalBlobStore(root),
    fetch: async (input) => {
      calls += 1;
      assert.deepEqual(input.policy.contentTypes, ["image/png"]);
      return {
        status: "snapshotted",
        snapshot: makeSnapshot({
          sourceDocumentId: input.sourceDocumentId,
          fetchUrl: input.url,
          finalUrl: input.url,
          statusCode: 200,
          headers: { "content-type": "image/png", etag: '"media-v1"' },
          body: bytes,
        }),
      };
    },
  });
  assert.equal(worked, true);
  assert.equal(calls, 1);
  const version = (
    await db.query("SELECT * FROM media_versions WHERE asset_id=$1", [mediaID])
  ).rows[0];
  assert.equal(version.version, 1);
  assert.equal(version.byte_size, 24);
  const published = (
    await db.query("SELECT bundle FROM events WHERE id=$1", [eventID])
  ).rows[0].bundle;
  assert.equal(
    published.mediaAssets.find((asset: any) => asset.id === mediaID)
      .contentHash,
    undefined,
  );
  const pending = (
    await db.query(
      "SELECT proposal,issues FROM review_cases WHERE event_id=$1 AND status='pending'",
      [eventID],
    )
  ).rows;
  assert.equal(pending.length, 1);
  const proposed = pending[0]!.proposal.mediaAssets.find(
    (asset: any) => asset.id === mediaID,
  );
  assert.equal(proposed.contentHash, version.content_hash);
  assert.equal(proposed.version, 1);
  assert.deepEqual(
    pending[0]!.proposal.evidence
      .filter((evidence: any) => evidence.recordID === mediaID)
      .map((evidence: any) => [evidence.field, evidence.verification])
      .sort(),
    [
      ["kind", "needsReview"],
      ["scope", "needsReview"],
    ],
  );
  assert.equal(pending[0]!.issues[0].code, "media_content_changed");
  const reviewID = (
    await db.query(
      "SELECT id FROM review_cases WHERE event_id=$1 AND status='pending'",
      [eventID],
    )
  ).rows[0].id;
  await assert.rejects(
    publishReview(db, reviewID, "unsafe", "Must require media re-verification"),
    /Missing confirmed evidence/,
  );
  assert.equal(
    (await db.query("SELECT status FROM jobs WHERE kind='media.fetch'")).rows[0]
      .status,
    "done",
  );
  const origin = (
    await db.query(
      "SELECT daily_requests,daily_bytes,fetch_lease_token FROM source_origins WHERE origin=$1",
      ["https://media.example.test"],
    )
  ).rows[0];
  assert.equal(Number(origin.daily_requests), 6);
  assert.equal(Number(origin.daily_bytes), bytes.length);
  assert.equal(origin.fetch_lease_token, null);
});

test("budget contention requeues without fetching or consuming a retry attempt", async (t) => {
  const db = await testDB();
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-budget-"),
  );
  t.after(async () => {
    await db.close();
    await rm(root, { recursive: true, force: true });
  });
  await publishedMedia(db);
  await db.query(
    "UPDATE source_origins SET policy=$2,daily_requests=100,budget_date=CURRENT_DATE WHERE origin=$1",
    ["https://media.example.test", JSON.stringify(approvedPolicy)],
  );
  await scheduleMedia(db);
  let calls = 0;
  assert.equal(
    await runMediaJob(db, {
      blobs: new LocalBlobStore(root),
      fetch: async () => {
        calls += 1;
        throw new Error("not reached");
      },
    }),
    true,
  );
  assert.equal(calls, 0);
  const job = (
    await db.query("SELECT status,attempts FROM jobs WHERE kind='media.fetch'")
  ).rows[0];
  assert.equal(job.status, "queued");
  assert.equal(Number(job.attempts), 0);
});

test("retryable media failures stop at the queue retry limit", async (t) => {
  const db = await testDB();
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-retry-"),
  );
  t.after(async () => {
    await db.close();
    await rm(root, { recursive: true, force: true });
  });
  await publishedMedia(db);
  await db.query("UPDATE source_origins SET policy=$2 WHERE origin=$1", [
    "https://media.example.test",
    JSON.stringify(approvedPolicy),
  ]);
  await scheduleMedia(db);
  let calls = 0;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    await db.query(
      "UPDATE jobs SET run_at=now()-interval '1 second' WHERE kind='media.fetch'",
    );
    await db.query(
      "UPDATE source_origins SET next_allowed_at=now()-interval '1 second' WHERE origin=$1",
      ["https://media.example.test"],
    );
    await runMediaJob(db, {
      blobs: new LocalBlobStore(root),
      fetch: async () => {
        calls += 1;
        return {
          status: "retryable_failure",
          issue: "synthetic timeout",
          redirectChain: [],
        };
      },
    });
  }
  assert.equal(calls, 3);
  const job = (
    await db.query(
      "SELECT status,attempts,last_error FROM jobs WHERE kind='media.fetch'",
    )
  ).rows[0];
  assert.equal(job.status, "failed");
  assert.equal(Number(job.attempts), 3);
  assert.match(job.last_error, /synthetic timeout/);
});

test("candidate jobs fetch every discovered image without publishing or upgrading link_only", async (t) => {
  const db = await testDB();
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-candidate-worker-"),
  );
  t.after(async () => {
    await db.close();
    await rm(root, { recursive: true, force: true });
  });
  await db.query(
    "INSERT INTO source_origins(id,origin,policy) VALUES($1,$2,$3)",
    [
      randomUUID(),
      "https://media.example.test",
      JSON.stringify(approvedPolicy),
    ],
  );
  const html = [
    "<h2>Goods</h2>",
    ...Array.from(
      { length: 12 },
      (_, index) =>
        `<img src="/approved/goods-${index}.png" alt="item ${index}">`,
    ),
  ].join("");
  assert.equal(
    await enqueueDiscoveredCandidateMedia(db, {
      html,
      pageURL: "https://media.example.test/event",
      displayPolicy: "permitted_cache",
      now: new Date("2026-09-22T12:00:00Z"),
    }),
    12,
  );
  assert.equal(
    await enqueueDiscoveredCandidateMedia(db, {
      html,
      pageURL: "https://media.example.test/event",
      displayPolicy: "permitted_cache",
      now: new Date("2026-09-22T12:00:00Z"),
    }),
    0,
  );
  assert.equal(
    (await db.query("SELECT id FROM jobs WHERE kind='media.fetch'")).rows.length,
    0,
  );
  const candidates = new MemoryCandidateStore();
  let calls = 0;
  const worked = await runCandidateMediaJob(db, {
    blobs: new LocalBlobStore(root),
    candidates,
    fetch: async (input) => {
      calls += 1;
      assert.equal(input.policy.host, "media.example.test");
      const index = Number(input.url.match(/goods-(\d+)/)?.[1]);
      return {
        status: "snapshotted",
        snapshot: makeSnapshot({
          sourceDocumentId: input.sourceDocumentId,
          fetchUrl: input.url,
          finalUrl: input.url,
          statusCode: 200,
          headers: { "content-type": "image/png", etag: `"g${index}"` },
          body: png(20 + index, 10),
        }),
      };
    },
  });
  assert.equal(worked, true);
  assert.equal(calls, 1);
  const stored = await candidates.list();
  assert.equal(stored.length, 1);
  assert.equal(stored[0]?.state, "ready");
  assert.equal(stored[0]?.displayPolicy, "permitted_cache");
  assert.ok(stored[0]?.current?.preview);
  assert.equal(
    (await db.query("SELECT id FROM review_cases")).rows.length,
    0,
  );
  assert.equal(
    (
      await db.query(
        "SELECT status FROM jobs WHERE kind='candidate.media.fetch' AND status='done'",
      )
    ).rows.length,
    1,
  );

  await db.query(
    "UPDATE jobs SET status='done' WHERE kind='candidate.media.fetch' AND status='queued'",
  );
  assert.equal(
    await enqueueDiscoveredCandidateMedia(db, {
      html: `<a href="/approved/poster.png">poster</a>`,
      pageURL: "https://media.example.test/event",
      displayPolicy: "link_only",
      now: new Date("2026-09-22T12:00:00Z"),
    }),
    1,
  );
  let linkCalls = 0;
  assert.equal(
    await runCandidateMediaJob(db, {
      blobs: new LocalBlobStore(root),
      candidates,
      fetch: async () => {
        linkCalls += 1;
        throw new Error("must not fetch");
      },
    }),
    true,
  );
  assert.equal(linkCalls, 0);
  const link = (await candidates.list()).find(
    (record) => record.displayPolicy === "link_only",
  );
  assert.equal(link?.state, "candidate");
  assert.equal(link?.versions.length, 0);
  assert.equal(
    (await db.query("SELECT id FROM review_cases")).rows.length,
    0,
  );
});
