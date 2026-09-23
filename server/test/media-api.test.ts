import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { testDB, seededBundle } from "./support.js";
import { LocalBlobStore } from "../src/storage/index.js";
import { PostgresMediaVersionRepository } from "../src/media.js";
import { createApp } from "../src/api.js";
import { createReview, publishReview } from "../src/publisher.js";
import { parseBundle } from "../src/contracts.js";

test("media API exposes only the reviewed cached version and honors revoked display permission", async () => {
  const root = await mkdtemp(join(tmpdir(), "livedash-media-api-"));
  const prior = process.env.BLOB_ROOT;
  process.env.BLOB_ROOT = root;
  const db = await testDB();
  const app = createApp(db, {
    adminToken: "test-admin-media-credential-32-characters",
  });
  try {
    const base = await seededBundle(db);
    const store = new LocalBlobStore(root);
    const versions = new PostgresMediaVersionRepository(db);
    const id = randomUUID();
    const png = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jz1kAAAAASUVORK5CYII=",
      "base64",
    );
    const blob = await store.put({ namespace: "media", bytes: png });
    const sourceURL = base.evidence[0]!.sourceURL;
    const descriptor = {
      assetID: id,
      originalURL: "https://example.org/map.png",
      finalURL: "https://example.org/map.png",
      contentHash: blob.sha256,
      blobKey: blob.key,
      mediaType: "image/png" as const,
      byteSize: png.length,
      responseHeaders: { "content-type": "image/png" },
      fetchedAt: new Date().toISOString(),
      displayPolicy: "permitted_cache" as const,
    };
    await versions.record(descriptor);
    assert.equal(
      (await app.inject(`/admin/media/${id}/versions/1`)).statusCode,
      401,
    );
    assert.equal(
      (
        await app.inject({
          url: `/admin/media/${id}/versions/1`,
          headers: {
            authorization: "Bearer test-admin-media-credential-32-characters",
          },
        })
      ).statusCode,
      200,
    );
    let b = parseBundle({
      ...base,
      mediaAssets: [
        {
          id,
          eventID: base.event.id,
          kind: "eventSeatingMap",
          originalURL: descriptor.originalURL,
          scope: {
            kind: "performances",
            performanceIDs: [base.performances[0]!.id],
          },
          sourceURL,
          version: 1,
          displayPolicy: "permitted_cache",
        },
      ],
      evidence: [
        ...base.evidence,
        ...["kind", "scope"].map((field) => ({
          ...base.evidence[0],
          id: randomUUID(),
          recordID: id,
          field,
        })),
      ],
    });
    let review = await createReview(db, b, 0);
    await publishReview(
      db,
      review.id,
      "test",
      "Unpublished bytes remain inaccessible",
    );
    assert.equal((await app.inject(`/v1/media/${id}/content`)).statusCode, 404);
    b.mediaAssets[0]!.contentHash = blob.sha256;
    review = await createReview(db, b, 1);
    await publishReview(db, review.id, "test", "Approve media content version");
    let response = await app.inject(`/v1/media/${id}/content`);
    assert.equal(response.statusCode, 200);
    assert.deepEqual(response.rawPayload, png);
    const newer = await store.put({
      namespace: "media",
      bytes: Buffer.concat([png, Buffer.from("new-content")]),
    });
    await versions.record({
      ...descriptor,
      blobKey: newer.key,
      contentHash: newer.sha256,
      byteSize: newer.byteSize,
    });
    response = await app.inject(`/v1/media/${id}/content`);
    assert.deepEqual(
      response.rawPayload,
      png,
      "New cached bytes are not silently published",
    );
    b.mediaAssets[0]!.displayPolicy = "link_only";
    review = await createReview(db, b, 2);
    await publishReview(db, review.id, "test", "Revoke inline display");
    assert.equal((await app.inject(`/v1/media/${id}/content`)).statusCode, 404);
  } finally {
    await app.close();
    await db.close();
    if (prior === undefined) delete process.env.BLOB_ROOT;
    else process.env.BLOB_ROOT = prior;
    await rm(root, { recursive: true, force: true });
  }
});
