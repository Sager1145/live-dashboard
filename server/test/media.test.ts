import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import type { SourcePolicy } from "../src/ingestion/types.js";
import {
  cacheMedia,
  inspectMedia,
  mediaPresentation,
  MemoryMediaVersionRepository,
  PostgresMediaVersionRepository,
  type RecordMediaVersionInput,
} from "../src/media.js";
import { LocalBlobStore } from "../src/storage/index.js";
import { testDB } from "./support.js";

const policy: SourcePolicy = {
  id: "approved-media",
  enabled: true,
  reviewStatus: "approved",
  robotsCheckedAt: "2026-09-22T00:00:00Z",
  termsReviewedAt: "2026-09-22T00:00:00Z",
  host: "media.example.com",
  allowedPaths: ["/approved/"],
  contentTypes: [
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "application/pdf",
    "image/svg+xml",
  ],
};

function png(width: number, height: number): Buffer {
  const value = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(value);
  value.write("IHDR", 12, "ascii");
  value.writeUInt32BE(width, 16);
  value.writeUInt32BE(height, 20);
  return value;
}

function snapshot(bytes: Buffer, contentType: string) {
  return makeSnapshot({
    sourceDocumentId: "media:asset",
    fetchUrl: "https://media.example.com/approved/map.png",
    finalUrl: "https://media.example.com/approved/map.png",
    statusCode: 200,
    headers: {
      "content-type": contentType,
      etag: `"${bytes.toString("hex")}"`,
    },
    fetchedAt: "2026-09-22T12:00:00Z",
    body: bytes,
  });
}

test("magic validation accepts supported image/PDF headers and rejects SVG or MIME disguise", () => {
  assert.deepEqual(inspectMedia(png(640, 480), "image/png; charset=binary"), {
    mediaType: "image/png",
    width: 640,
    height: 480,
  });
  const gif = Buffer.alloc(10);
  gif.write("GIF89a", 0, "ascii");
  gif.writeUInt16LE(3, 6);
  gif.writeUInt16LE(2, 8);
  assert.deepEqual(inspectMedia(gif, "image/gif"), {
    mediaType: "image/gif",
    width: 3,
    height: 2,
  });
  const jpeg = Buffer.from([
    0xff, 0xd8, 0xff, 0xc0, 0x00, 0x07, 0x08, 0x00, 0x02, 0x00, 0x03,
  ]);
  assert.deepEqual(inspectMedia(jpeg, "image/jpeg"), {
    mediaType: "image/jpeg",
    width: 3,
    height: 2,
  });
  assert.deepEqual(
    inspectMedia(Buffer.from("%PDF-1.7\nsynthetic"), "application/pdf"),
    { mediaType: "application/pdf" },
  );
  assert.throws(
    () => inspectMedia(Buffer.from("<svg><script/></svg>"), "image/svg+xml"),
    /SVG/,
  );
  assert.throws(() => inspectMedia(png(1, 1), "image/jpeg"), /does not match/);
  assert.throws(
    () => inspectMedia(png(20_000, 20_000), "image/png"),
    /exceeds/,
  );
});

test("link-only and remote-display policy never invoke the downloader", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-policy-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  let calls = 0;
  const common = {
    sourcePolicy: policy,
    blobs: new LocalBlobStore(root),
    versions: new MemoryMediaVersionRepository(),
    fetch: async () => {
      calls += 1;
      throw new Error("must not fetch");
    },
  };
  const link = await cacheMedia({
    ...common,
    asset: {
      id: "link",
      originalURL: "https://media.example.com/approved/map.png",
      displayPolicy: "link_only",
    },
  });
  const remote = await cacheMedia({
    ...common,
    asset: {
      id: "remote",
      originalURL: "https://media.example.com/approved/map.png",
      displayPolicy: "permitted_remote_display",
      approvedMediaType: "image/png",
    },
  });
  assert.equal(calls, 0);
  assert.equal(link.status, "not_fetched");
  assert.deepEqual(link.status === "not_fetched" && link.presentation, {
    kind: "link",
    linkURL: "https://media.example.com/approved/map.png",
    renderInline: false,
  });
  assert.equal(remote.status, "not_fetched");
  assert.equal(
    remote.status === "not_fetched" && remote.presentation.kind,
    "remote",
  );
  assert.equal(
    mediaPresentation({
      id: "svg",
      originalURL: "https://media.example.com/approved/drawing.svg",
      displayPolicy: "permitted_remote_display",
      approvedMediaType: "image/png",
    }).kind,
    "link",
  );
  assert.equal(
    mediaPresentation({
      id: "unknown",
      originalURL: "https://media.example.com/approved/no-type",
      displayPolicy: "permitted_remote_display",
    }).kind,
    "link",
  );
});

test("cache-approved media uses the controlled fetch boundary and versions changed bytes at the same URL", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-cache-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  const blobs = new LocalBlobStore(root);
  const versions = new MemoryMediaVersionRepository();
  const bodies = [png(640, 480), png(800, 600), png(800, 600)];
  let calls = 0;
  const fetch = async (
    input: Parameters<
      NonNullable<Parameters<typeof cacheMedia>[0]["fetch"]>
    >[0],
  ) => {
    assert.equal(input.url, "https://media.example.com/approved/map.png");
    assert.ok(input.policy.contentTypes?.includes("image/png"));
    assert.ok(!input.policy.contentTypes?.includes("image/svg+xml"));
    assert.equal(input.policy.maxDecompressedBytes, 25 * 1024 * 1024);
    const body = bodies[calls++]!;
    return {
      status: "snapshotted" as const,
      snapshot: snapshot(body, "image/png"),
    };
  };
  const asset = {
    id: "asset",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "permitted_cache" as const,
  };

  const first = await cacheMedia({
    asset,
    sourcePolicy: policy,
    blobs,
    versions,
    fetch,
  });
  const second = await cacheMedia({
    asset,
    sourcePolicy: policy,
    blobs,
    versions,
    fetch,
  });
  const third = await cacheMedia({
    asset,
    sourcePolicy: policy,
    blobs,
    versions,
    fetch,
  });
  assert.equal(first.status, "cached");
  assert.equal(second.status, "cached");
  assert.equal(third.status, "unchanged");
  if (
    first.status === "cached" &&
    second.status === "cached" &&
    third.status === "unchanged"
  ) {
    assert.equal(first.version.version, 1);
    assert.equal(second.version.version, 2);
    assert.equal(third.version.version, 2);
    assert.notEqual(first.version.contentHash, second.version.contentHash);
    assert.equal(await blobs.has(second.version.blobKey), true);
    assert.equal(second.presentation.kind, "cached");
  }
  assert.equal(calls, 3);
});

test("disabled policies and invalid bytes are blocked without recording a version", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-block-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  const versions = new MemoryMediaVersionRepository();
  let calls = 0;
  const asset = {
    id: "asset",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "permitted_cache" as const,
  };
  const disabled = await cacheMedia({
    asset,
    sourcePolicy: { ...policy, enabled: false },
    blobs: new LocalBlobStore(root),
    versions,
    fetch: async () => {
      calls += 1;
      return {
        status: "snapshotted",
        snapshot: snapshot(png(1, 1), "image/png"),
      };
    },
  });
  assert.equal(disabled.status, "blocked");
  assert.equal(calls, 0);
  const htmlOnly = await cacheMedia({
    asset,
    sourcePolicy: { ...policy, contentTypes: undefined },
    blobs: new LocalBlobStore(root),
    versions,
    fetch: async () => {
      calls += 1;
      return {
        status: "snapshotted",
        snapshot: snapshot(png(1, 1), "image/png"),
      };
    },
  });
  assert.equal(htmlOnly.status, "blocked");
  assert.match(
    htmlOnly.status === "blocked" ? htmlOnly.issue : "",
    /does not approve/,
  );
  assert.equal(calls, 0);
  const disguised = await cacheMedia({
    asset,
    sourcePolicy: policy,
    blobs: new LocalBlobStore(root),
    versions,
    fetch: async () => ({
      status: "snapshotted",
      snapshot: snapshot(Buffer.from("not an image"), "image/png"),
    }),
  });
  assert.equal(disguised.status, "blocked");
  assert.equal(await versions.latest(asset.id), undefined);
});

test("Postgres repository atomically keeps a stable version for identical content and increments changes", async () => {
  const db = await testDB();
  try {
    const repository = new PostgresMediaVersionRepository(db);
    const base: RecordMediaVersionInput = {
      assetID: "media-asset",
      originalURL: "https://media.example.com/approved/map.png",
      finalURL: "https://media.example.com/approved/map.png",
      contentHash: "a".repeat(64),
      blobKey: `media/sha256/aa/${"a".repeat(64)}`,
      mediaType: "image/png",
      byteSize: 24,
      width: 1,
      height: 1,
      responseHeaders: { "content-type": "image/png" },
      fetchedAt: "2026-09-22T12:00:00Z",
      displayPolicy: "permitted_cache",
    };
    const first = await repository.record(base);
    const repeat = await repository.record(base);
    const changed = await repository.record({
      ...base,
      contentHash: "b".repeat(64),
      blobKey: `media/sha256/bb/${"b".repeat(64)}`,
    });
    assert.equal(first.created, true);
    assert.equal(first.version.version, 1);
    assert.equal(repeat.created, false);
    assert.equal(repeat.version.version, 1);
    assert.equal(changed.created, true);
    assert.equal(changed.version.version, 2);
    assert.equal(
      (await repository.latest(base.assetID))?.contentHash,
      "b".repeat(64),
    );
    const columns = await db.query(
      "SELECT blob_key,byte_size FROM source_snapshots LIMIT 0",
    );
    assert.deepEqual(columns.rows, []);
  } finally {
    await db.close();
  }
});
