import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import type { SourcePolicy } from "../src/ingestion/types.js";
import { createHash } from "node:crypto";
import {
  cacheMedia,
  canServeAsset,
  collapseLogicalImages,
  discoverCandidateImages,
  fetchCandidateMedia,
  inspectMedia,
  mediaPresentation,
  MemoryMediaVersionRepository,
  PostgresMediaVersionRepository,
  type RecordMediaVersionInput,
} from "../src/media.js";
import { LocalBlobStore, MemoryCandidateStore } from "../src/storage/index.js";
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

test("candidate bytes stay private until published, and link_only is never upgraded", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-candidate-policy-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  const blobs = new LocalBlobStore(root);
  const candidates = new MemoryCandidateStore();
  let calls = 0;
  const blocked = await fetchCandidateMedia({
    candidateID: "link-image",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "link_only",
    sourcePolicy: policy,
    blobs,
    candidates,
    fetch: async () => {
      calls += 1;
      throw new Error("must not fetch link_only");
    },
  });
  assert.equal(calls, 0);
  assert.equal(blocked.status, "not_fetched");
  if (blocked.status === "not_fetched") {
    assert.equal(blocked.record.displayPolicy, "link_only");
    assert.equal(blocked.record.state, "candidate");
    assert.equal(blocked.record.versions.length, 0);
  }
  const upgraded = await fetchCandidateMedia({
    candidateID: "link-image",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "permitted_cache",
    sourcePolicy: policy,
    blobs,
    candidates,
    fetch: async () => {
      calls += 1;
      throw new Error("must not upgrade link_only");
    },
  });
  assert.equal(calls, 0);
  assert.equal(upgraded.status, "not_fetched");
  if (upgraded.status === "not_fetched")
    assert.equal(upgraded.record.displayPolicy, "link_only");
  const hash = "c".repeat(64);
  assert.equal(
    canServeAsset({
      published: false,
      state: "ready",
      displayPolicy: "permitted_cache",
      contentHash: hash,
    }),
    false,
  );
  assert.equal(
    canServeAsset({
      published: true,
      state: "candidate",
      displayPolicy: "permitted_cache",
      contentHash: hash,
    }),
    false,
  );
  assert.equal(
    canServeAsset({
      published: true,
      state: "pending",
      displayPolicy: "permitted_cache",
      contentHash: hash,
    }),
    false,
  );
  assert.equal(
    canServeAsset({
      published: true,
      state: "ready",
      displayPolicy: "link_only",
      contentHash: hash,
    }),
    false,
  );
  assert.equal(
    canServeAsset({
      published: true,
      state: "ready",
      displayPolicy: "permitted_cache",
      contentHash: hash,
    }),
    true,
  );
});

test("candidate fetch keeps old bytes when the same URL changes and ignores an HTML 304", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-media-candidate-bytes-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  const blobs = new LocalBlobStore(root);
  const candidates = new MemoryCandidateStore();
  const bodies = [png(32, 16), png(64, 16)];
  let calls = 0;
  const fetch = async (
    input: Parameters<
      NonNullable<Parameters<typeof fetchCandidateMedia>[0]["fetch"]>
    >[0],
  ) => {
    calls += 1;
    if (calls === 3) {
      assert.ok(input.previousSnapshot);
      return {
        status: "unchanged" as const,
        snapshot: input.previousSnapshot!,
        validatedAt: "2026-09-22T13:00:00Z",
        checkedAt: "2026-09-22T13:00:00Z",
      };
    }
    const body = bodies[calls - 1]!;
    return {
      status: "snapshotted" as const,
      snapshot: snapshot(body, "image/png"),
    };
  };
  const input = {
    candidateID: "same-url",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "permitted_cache" as const,
    sourcePolicy: policy,
    blobs,
    candidates,
    fetch,
  };
  const first = await fetchCandidateMedia(input);
  const second = await fetchCandidateMedia(input);
  const third = await fetchCandidateMedia(input);
  assert.equal(first.status, "ready");
  assert.equal(second.status, "ready");
  assert.equal(third.status, "unchanged");
  if (first.status === "ready" && second.status === "ready") {
    assert.equal(first.createdNewBytes, true);
    assert.equal(second.createdNewBytes, true);
    assert.notEqual(
      first.record.current?.contentHash,
      second.record.current?.contentHash,
    );
    assert.equal(second.record.versions.length, 2);
    assert.equal(await blobs.has(first.record.versions[0]!.blobKey), true);
    assert.equal(await blobs.has(second.record.current!.blobKey), true);
    assert.equal(first.record.current?.preview?.mediaType, "image/png");
    const preview = await blobs.read(first.record.current!.preview!.blobKey);
    assert.equal(
      createHash("sha256").update(preview).digest("hex"),
      first.record.current?.preview?.contentHash,
    );
    assert.equal(third.status === "unchanged" && third.record.versions.length, 2);
    assert.equal(
      third.status === "unchanged" && third.record.current?.contentHash,
      second.record.current?.contentHash,
    );
  }
  assert.equal(calls, 3);

  const pdf = await fetchCandidateMedia({
    ...input,
    candidateID: "pdf-note",
    originalURL: "https://media.example.com/approved/note.pdf",
    fetch: async () => ({
      status: "snapshotted",
      snapshot: snapshot(Buffer.from("%PDF-1.7\nsynthetic"), "application/pdf"),
    }),
  });
  assert.equal(pdf.status, "ready");
  if (pdf.status === "ready") {
    assert.equal(pdf.record.current?.mediaType, "application/pdf");
    assert.equal(pdf.record.current?.preview, undefined);
    assert.equal(
      canServeAsset({
        published: false,
        state: pdf.record.state,
        displayPolicy: pdf.record.displayPolicy,
        contentHash: pdf.record.current?.contentHash ?? "",
      }),
      false,
    );
  }
});

test("srcset duplicates collapse by bytes and distinct goods images are not capped", () => {
  const images = Array.from({ length: 12 }, (_, index) => {
    const bytes = png(40 + index, 80);
    return {
      url: `https://media.example.com/approved/goods-${index}.png`,
      contentHash: createHash("sha256").update(bytes).digest("hex"),
      order: index,
      section: "Goods",
      caption: `item ${index}`,
    };
  });
  const srcsetTwin = {
    url: "https://media.example.com/approved/goods-0-800w.png",
    contentHash: images[0]!.contentHash,
    order: 0,
    section: "Goods",
    caption: "item 0 large",
  };
  const otherCrop = {
    url: "https://media.example.com/approved/goods-0-crop.png",
    contentHash: createHash("sha256").update(png(40, 81)).digest("hex"),
    order: 12,
    section: "Goods",
    caption: "item 0 crop",
  };
  const groups = collapseLogicalImages([...images, srcsetTwin, otherCrop]);
  assert.equal(groups.length, 13);
  assert.deepEqual(groups[0]?.urls, [
    images[0]!.url,
    srcsetTwin.url,
  ]);
  assert.equal(groups.at(-1)?.urls[0], otherCrop.url);
  assert.notEqual(groups[0]?.logicalImageID, groups.at(-1)?.logicalImageID);

  const html = [
    "<h2>Goods</h2>",
    ...Array.from(
      { length: 12 },
      (_, index) =>
        `<img src="/approved/goods-${index}.png" alt="item ${index}">`,
    ),
    `<img srcset="/approved/goods-0.png 400w, /approved/goods-0-800w.png 800w" alt="item 0">`,
    `<img src="/approved/pixel.gif" width="1" height="1" alt="">`,
    `<img class="icon" src="/approved/icons/cart.png" alt="">`,
  ].join("");
  const discovered = discoverCandidateImages(
    html,
    "https://media.example.com/event",
  );
  assert.equal(discovered.length, 13);
  assert.equal(discovered[0]?.section, "Goods");
  assert.ok(discovered.every((image) => image.url.startsWith("https://")));
  assert.equal(
    discovered.filter((image) => image.url.endsWith("/approved/goods-0.png"))
      .length,
    1,
  );
  assert.ok(
    discovered.some((image) => image.url.endsWith("/approved/goods-0-800w.png")),
  );
  assert.ok(discovered.every((image) => !image.url.includes("pixel.gif")));
  assert.ok(discovered.every((image) => !image.url.includes("/icons/")));
});
