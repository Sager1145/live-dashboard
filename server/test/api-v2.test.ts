import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { testDB, seededBundle } from "./support.js";
import { createApp } from "../src/api.js";
import { createReview, publishReview, withdrawEvent } from "../src/publisher.js";
import { LocalBlobStore } from "../src/storage/index.js";
import { PostgresMediaVersionRepository } from "../src/media.js";
import {
  catalogBootstrapSchema,
  metaSchema,
  parseCatalogChanges,
  updateJobAcceptedSchema,
  updateJobStatusSchema,
} from "../src/contracts.js";

const adminToken = "test-only-admin-secret-at-least-24-characters";
const ownerHeaders = {
  authorization: `Bearer ${adminToken}`,
  "idempotency-key": "owner-key",
};
const catalogJob = {
  target: { kind: "catalog" },
  fetchLatest: true,
  reextract: false,
  reason: "owner_requested",
};

async function published(db: Awaited<ReturnType<typeof testDB>>) {
  const bundle = await seededBundle(db);
  const review = await createReview(db, bundle, 0);
  await publishReview(db, review.id, "tester", "Initial");
  return bundle;
}

test("v2 catalog keeps one snapshot, decimal cursors, and v1 schemaVersion 1", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const first = await published(db);
    const second = await published(db);
    const v1 = await app.inject("/v1/catalog/bootstrap");
    assert.equal(v1.statusCode, 200);
    assert.equal(v1.json().schemaVersion, 1);
    assert.equal(v1.json().events[0].schemaVersion, 1);
    const page1 = await app.inject("/v2/catalog/bootstrap?limit=1");
    assert.equal(page1.statusCode, 200);
    const doc1 = catalogBootstrapSchema.parse(page1.json());
    assert.equal(doc1.schemaVersion, 2);
    assert.equal(doc1.events.length, 1);
    assert.equal(doc1.hasMore, true);
    assert.equal(typeof doc1.cursor, "string");
    assert.equal(typeof doc1.watermark, "string");
    const third = await published(db);
    const page2 = await app.inject(
      `/v2/catalog/bootstrap?page=${encodeURIComponent(doc1.nextPageToken!)}`,
    );
    const doc2 = catalogBootstrapSchema.parse(page2.json());
    assert.equal(doc2.snapshotID, doc1.snapshotID);
    assert.equal(doc2.watermark, doc1.watermark);
    assert.equal(doc2.cursor, doc1.cursor);
    assert.equal(doc2.hasMore, false);
    const seen = new Set([
      doc1.events[0]!.event.id,
      doc2.events[0]!.event.id,
    ]);
    assert.equal(seen.has(third.event.id), false);
    assert.deepEqual(seen, new Set([first.event.id, second.event.id]));
    const again = await app.inject("/v1/catalog/bootstrap");
    assert.equal(again.json().schemaVersion, 1);
    assert.equal(again.json().events[0].schemaVersion, 1);
    assert.equal(
      again.json().events.every((event: { schemaVersion: number }) => event.schemaVersion === 1),
      true,
    );
  } finally {
    await app.close();
    await db.close();
  }
});

test("v2 changes use a fixed watermark and refuse an unknown kind without moving the cursor", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const first = await published(db);
    const second = await published(db);
    await withdrawEvent(db, first.event.id, 1, "tester", "Merge", second.event.id);
    const delta = await app.inject("/v2/catalog/changes?cursor=0");
    assert.equal(delta.statusCode, 200);
    const parsed = parseCatalogChanges(delta.json());
    assert.equal(typeof parsed.cursor, "string");
    assert.equal(typeof parsed.watermark, "string");
    assert.equal(parsed.changes.some((change) => change.kind === "remap"), true);
    assert.equal(
      parsed.changes.every((change) =>
        change.kind !== "upsert" || change.bundle.schemaVersion === 2,
      ),
      true,
    );
    const v1 = await app.inject("/v1/catalog/changes?cursor=0");
    assert.equal(v1.json().schemaVersion, undefined);
    assert.equal(v1.json().changes.at(-1).kind, "remap");
    assert.equal(v1.json().changes[0].bundle.schemaVersion, 1);
    await db.query(
      "ALTER TABLE catalog_changes DROP CONSTRAINT catalog_changes_kind_check",
    );
    const clock = (
      await db.query(
        "UPDATE catalog_clock SET value=value+1 WHERE singleton RETURNING value",
      )
    ).rows[0].value;
    await db.query(
      "INSERT INTO catalog_changes(sequence,event_id,revision,kind) VALUES($1,$2,1,'invented')",
      [clock, first.event.id],
    );
    const blocked = await app.inject(
      `/v2/catalog/changes?cursor=${parsed.cursor}`,
    );
    assert.equal(blocked.statusCode, 422);
    assert.equal(blocked.json().cursor, undefined);
    const retried = await app.inject(
      `/v2/catalog/changes?cursor=${parsed.cursor}`,
    );
    assert.equal(retried.statusCode, 422);
    await db.query("DELETE FROM catalog_changes WHERE kind='invented'");
    await db.query(
      "INSERT INTO catalog_changes(sequence,event_id,revision,kind,bundle) SELECT 9007199254740993,event_id,revision,'upsert',bundle FROM catalog_changes WHERE sequence=1",
    );
    await db.query("UPDATE catalog_clock SET value=9007199254740993");
    const wide = parseCatalogChanges(
      (await app.inject("/v2/catalog/changes?cursor=0&limit=20")).json(),
    );
    assert.equal(wide.cursor, "9007199254740993");
    assert.equal(wide.watermark, "9007199254740993");
    assert.equal(
      wide.changes.some((change) => change.sequence === "9007199254740993"),
      true,
    );
  } finally {
    await app.close();
    await db.close();
  }
});

test("meta is public, limited, and has no account material", async () => {
  const db = await testDB();
  const app = createApp(db, {
    adminToken,
    metaRateLimit: { limit: 2, windowMs: 60_000 },
  });
  try {
    const first = metaSchema.parse((await app.inject("/v2/meta")).json());
    assert.deepEqual(first.schemaVersions, [1, 2]);
    assert.equal(first.capabilities.includes("update-jobs"), true);
    assert.equal(JSON.stringify(first).toLowerCase().includes("token"), false);
    assert.equal(JSON.stringify(first).toLowerCase().includes("account"), false);
    assert.equal((await app.inject("/v2/meta")).statusCode, 200);
    assert.equal((await app.inject("/v2/meta")).statusCode, 429);
    assert.equal((await app.inject("/health")).statusCode, 200);
  } finally {
    await app.close();
    await db.close();
  }
});

test("pairing is single-use, refresh rotates, and a receiver cannot own jobs", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const bundle = await published(db);
    const issued = (
      await app.inject({
        method: "POST",
        url: "/admin/pairings",
        headers: { authorization: `Bearer ${adminToken}` },
        payload: {},
      })
    ).json();
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: "/v2/pairings/complete",
          payload: { token: issued.token, challenge: "not-the-issued-challenge" },
        })
      ).statusCode,
      401,
    );
    const paired = await app.inject({
      method: "POST",
      url: "/v2/pairings/complete",
      payload: { token: issued.token, challenge: issued.challenge },
    });
    assert.equal(paired.statusCode, 201);
    assert.equal(paired.json().role, "receiver");
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: "/v2/pairings/complete",
          payload: { token: issued.token, challenge: issued.challenge },
        })
      ).statusCode,
      401,
    );
    const refreshed = await app.inject({
      method: "POST",
      url: "/v2/auth/refresh",
      headers: { authorization: `Bearer ${paired.json().credential}` },
    });
    assert.equal(refreshed.statusCode, 200);
    assert.notEqual(refreshed.json().credential, paired.json().credential);
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: "/v2/auth/refresh",
          headers: { authorization: `Bearer ${paired.json().credential}` },
        })
      ).statusCode,
      401,
    );
    const receiver = {
      authorization: `Bearer ${refreshed.json().credential}`,
      "idempotency-key": "receiver-key",
    };
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url: `/v2/installations/${paired.json().id}/push-token`,
          headers: { authorization: receiver.authorization },
          payload: { token: "ab".repeat(32), environment: "sandbox" },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url: `/v2/installations/${paired.json().id}/subscriptions`,
          headers: { authorization: receiver.authorization },
          payload: {
            subscriptions: [
              {
                eventID: bundle.event.id,
                performanceIDs: [bundle.performances[0]!.id],
              },
            ],
          },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: "/v2/update-jobs",
          headers: receiver,
          payload: catalogJob,
        })
      ).statusCode,
      403,
    );
    const created = await app.inject({
      method: "POST",
      url: "/v2/update-jobs",
      headers: { ...ownerHeaders, "idempotency-key": "job-a" },
      payload: catalogJob,
    });
    assert.equal(created.statusCode, 202);
    const accepted = updateJobAcceptedSchema.parse(created.json());
    assert.equal(accepted.deduplicated, false);
    const replay = await app.inject({
      method: "POST",
      url: "/v2/update-jobs",
      headers: { ...ownerHeaders, "idempotency-key": "job-a" },
      payload: catalogJob,
    });
    assert.deepEqual(replay.json(), accepted);
    const merged = await app.inject({
      method: "POST",
      url: "/v2/update-jobs",
      headers: { ...ownerHeaders, "idempotency-key": "job-b" },
      payload: { ...catalogJob, reextract: true },
    });
    assert.equal(merged.statusCode, 202);
    assert.equal(merged.json().jobID, accepted.jobID);
    assert.equal(merged.json().deduplicated, true);
    const before = (
      await db.query("SELECT status, attempts FROM jobs WHERE id=$1", [
        accepted.jobID,
      ])
    ).rows[0];
    const status = await app.inject({
      url: accepted.statusPath,
      headers: { authorization: `Bearer ${adminToken}` },
    });
    assert.equal(status.statusCode, 200);
    assert.equal(updateJobStatusSchema.parse(status.json()).state, "queued");
    const after = (
      await db.query("SELECT status, attempts FROM jobs WHERE id=$1", [
        accepted.jobID,
      ])
    ).rows[0];
    assert.equal(after.status, before.status);
    assert.equal(String(after.attempts), String(before.attempts));
    assert.equal(
      (await db.query("SELECT count(*)::text AS n FROM source_fetches")).rows[0]
        .n,
      "0",
    );
    assert.equal(
      (
        await app.inject({
          url: accepted.statusPath,
          headers: { authorization: receiver.authorization },
        })
      ).statusCode,
      403,
    );
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `${accepted.statusPath}/cancel`,
          headers: { authorization: receiver.authorization },
        })
      ).statusCode,
      403,
    );
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: "/v2/update-jobs",
          headers: { ...ownerHeaders, "idempotency-key": "job-url" },
          payload: {
            target: { kind: "url", url: "https://evil.example/pull" },
            fetchLatest: true,
            reextract: true,
            reason: "owner_requested",
          },
        })
      ).statusCode,
      422,
    );
    const cancelled = await app.inject({
      method: "POST",
      url: `${accepted.statusPath}/cancel`,
      headers: { authorization: `Bearer ${adminToken}` },
    });
    assert.equal(cancelled.statusCode, 200);
    assert.equal(cancelled.json().state, "cancelled");
    assert.equal(
      (await db.query("SELECT count(*)::text AS n FROM events")).rows[0].n,
      "1",
    );
    const ownerPair = (
      await app.inject({
        method: "POST",
        url: "/admin/pairings",
        headers: { authorization: `Bearer ${adminToken}` },
        payload: { role: "owner" },
      })
    ).json();
    const owner = (
      await app.inject({
        method: "POST",
        url: "/v2/pairings/complete",
        payload: { token: ownerPair.token, challenge: ownerPair.challenge },
      })
    ).json();
    assert.equal(owner.role, "owner");
    const owned = await app.inject({
      method: "POST",
      url: "/v2/update-jobs",
      headers: {
        authorization: `Bearer ${owner.credential}`,
        "idempotency-key": "owner-device",
      },
      payload: catalogJob,
    });
    assert.equal(owned.statusCode, 202);
    assert.notEqual(owned.json().jobID, accepted.jobID);
    assert.equal(
      (
        await app.inject({
          method: "DELETE",
          url: `/v2/installations/${paired.json().id}`,
          headers: { authorization: `Bearer ${owner.credential}` },
        })
      ).statusCode,
      200,
    );
  } finally {
    await app.close();
    await db.close();
  }
});

test("candidate bytes stay private and expired cursors keep user rows", async () => {
  const root = await mkdtemp(join(tmpdir(), "livedash-v2-assets-"));
  const prior = process.env.BLOB_ROOT;
  process.env.BLOB_ROOT = root;
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const bundle = await seededBundle(db);
    const store = new LocalBlobStore(root);
    const versions = new PostgresMediaVersionRepository(db);
    const id = randomUUID();
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jz1kAAAAASUVORK5CYII=",
      "base64",
    );
    const blob = await store.put({ namespace: "media", bytes: png });
    const sourceURL = bundle.evidence[0]!.sourceURL;
    await versions.record({
      assetID: id,
      originalURL: "https://example.org/map.png",
      finalURL: "https://example.org/map.png",
      contentHash: blob.sha256,
      blobKey: blob.key,
      mediaType: "image/png",
      byteSize: png.length,
      width: 1,
      height: 1,
      responseHeaders: { "content-type": "image/png" },
      fetchedAt: new Date().toISOString(),
      displayPolicy: "permitted_cache",
    });
    const hidden = await app.inject(`/v2/assets/${blob.sha256}/original`);
    assert.equal(hidden.statusCode, 404);
    assert.equal(hidden.headers.location, undefined);
    bundle.mediaAssets = [
      {
        id,
        eventID: bundle.event.id,
        kind: "eventSeatingMap",
        originalURL: "https://example.org/map.png",
        scope: {
          kind: "performances",
          performanceIDs: [bundle.performances[0]!.id],
        },
        sourceURL,
        version: 1,
        displayPolicy: "permitted_cache",
        contentHash: blob.sha256,
        thumbnailURL: null,
        caption: null,
      },
    ];
    bundle.evidence.push(
      ...["kind", "scope"].map((field) => ({
        ...bundle.evidence[0]!,
        id: randomUUID(),
        recordID: id,
        field,
      })),
    );
    const review = await createReview(db, bundle, 0);
    await publishReview(db, review.id, "test", "Publish cached map");
    const body = await app.inject(`/v2/assets/${blob.sha256}/original`);
    assert.equal(body.statusCode, 200);
    assert.equal(body.headers.location, undefined);
    assert.deepEqual(body.rawPayload, png);
    assert.equal(
      (await app.inject(`/v2/assets/${blob.sha256}/preview`)).statusCode,
      404,
    );
    const newer = await store.put({
      namespace: "media",
      bytes: Buffer.concat([png, Buffer.from("candidate")]),
    });
    await versions.record({
      assetID: id,
      originalURL: "https://example.org/map.png",
      finalURL: "https://example.org/map.png",
      contentHash: newer.sha256,
      blobKey: newer.key,
      mediaType: "image/png",
      byteSize: newer.byteSize,
      width: 1,
      height: 1,
      responseHeaders: {},
      fetchedAt: new Date().toISOString(),
      displayPolicy: "permitted_cache",
    });
    assert.equal(
      (await app.inject(`/v2/assets/${newer.sha256}/original`)).statusCode,
      404,
    );
    const detail = await app.inject(`/v2/events/${bundle.event.id}`);
    assert.equal(detail.json().schemaVersion, 2);
    assert.equal(
      (
        await app.inject({
          url: `/v2/events/${bundle.event.id}`,
          headers: { "if-none-match": detail.headers.etag as string },
        })
      ).statusCode,
      304,
    );
    const evidenceID = bundle.evidence[0]!.id;
    await db.query(
      "UPDATE accepted_facts SET evidence = evidence || $2::jsonb WHERE evidence->>'id'=$1",
      [
        evidenceID,
        JSON.stringify({
          rawHTML: "<html><script>secret()</script></html>",
          quote: `${"quoted ".repeat(120)}<html>tail</html>`,
        }),
      ],
    );
    const evidence = await app.inject(`/v2/evidence/${evidenceID}`);
    assert.equal(evidence.statusCode, 200);
    assert.equal(evidence.json().quote.length <= 500, true);
    assert.equal(JSON.stringify(evidence.json()).includes("secret()"), false);
    assert.equal(evidence.json().rawHTML, undefined);
    await db.query(
      "UPDATE events SET bundle = jsonb_set(bundle, '{legacyAliases}', $2::jsonb, true) WHERE id=$1",
      [
        bundle.event.id,
        JSON.stringify({
          events: [{ legacyID: "legacy-event", currentID: bundle.event.id }],
          performances: [],
          tickets: [],
          goods: [],
        }),
      ],
    );
    const install = (
      await app.inject({ method: "POST", url: "/v1/installations", payload: {} })
    ).json();
    await db.query(
      "INSERT INTO subscriptions(installation_id,event_id,performance_ids) VALUES($1,$2,'[]')",
      [install.id, bundle.event.id],
    );
    const mappings = await app.inject("/v2/identity-mappings");
    assert.equal(mappings.statusCode, 200);
    assert.equal(mappings.json().mappings[0].legacyID, "legacy-event");
    assert.equal(JSON.stringify(mappings.json()).includes(install.id), false);
    await db.query("UPDATE catalog_clock SET minimum_cursor=value");
    const expired = await app.inject("/v2/catalog/changes?cursor=0");
    assert.equal(expired.statusCode, 410);
    assert.equal(
      (await db.query("SELECT count(*)::text AS n FROM subscriptions")).rows[0]
        .n,
      "1",
    );
    assert.equal(
      (await db.query("SELECT count(*)::text AS n FROM events")).rows[0].n,
      "1",
    );
    const v1 = await app.inject("/v1/catalog/bootstrap");
    assert.equal(v1.json().schemaVersion, 1);
    assert.equal(v1.json().events[0].schemaVersion, 1);
  } finally {
    await app.close();
    await db.close();
    if (prior === undefined) delete process.env.BLOB_ROOT;
    else process.env.BLOB_ROOT = prior;
    await rm(root, { recursive: true, force: true });
  }
});
