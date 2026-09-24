import test from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import {
  blobStoreFromEnv,
  LocalBlobStore,
  LocalCandidateStore,
  storeSnapshotBlob,
} from "../src/storage/index.js";

test("local blob store is private, content addressed, and idempotent", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "live-dashboard-blobs-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const store = new LocalBlobStore(root);
  const bytes = Buffer.from("private snapshot bytes");

  const first = await store.put({ namespace: "snapshots", bytes });
  const second = await store.put({
    namespace: "snapshots",
    bytes: Buffer.from(bytes),
  });
  assert.deepEqual(second, first);
  assert.match(first.key, /^snapshots\/sha256\/[a-f0-9]{2}\/[a-f0-9]{64}$/);
  assert.deepEqual(await store.read(first.key), bytes);
  assert.equal(await store.has(first.key), true);
  assert.equal((await stat(root)).mode & 0o777, 0o700);
  const storedPath = path.join(root, ...first.key.split("/"));
  assert.equal((await stat(storedPath)).mode & 0o777, 0o600);
  await assert.rejects(store.read("../outside"), /invalid blob key/);
  await assert.rejects(
    store.put({ namespace: "media", bytes, expectedSha256: "0".repeat(64) }),
    /does not match/,
  );
  await writeFile(storedPath, "corrupt restore", { mode: 0o600 });
  await assert.rejects(
    store.read(first.key),
    /does not match its content-address key/,
  );
  assert.deepEqual(await store.put({ namespace: "snapshots", bytes }), first);
  assert.deepEqual(await store.read(first.key), bytes);
});

test("snapshot helper stores exact response bytes and environment configuration is opt-in", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-snapshots-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  assert.equal(blobStoreFromEnv({}), undefined);
  const store = blobStoreFromEnv({ BLOB_ROOT: root });
  assert.ok(store);
  const snapshot = makeSnapshot({
    sourceDocumentId: "document",
    fetchUrl: "https://example.com/page",
    finalUrl: "https://example.com/page",
    statusCode: 200,
    headers: { "content-type": "text/html" },
    body: Buffer.from("<!doctype html><html>exact</html>"),
  });
  const saved = await storeSnapshotBlob(store, snapshot);
  assert.equal(saved.sha256, snapshot.rawSha256);
  assert.equal(saved.byteSize, snapshot.body.length);
  assert.deepEqual(await store.read(saved.key), snapshot.body);
});

test("local store rejects an existing public root instead of changing system directory permissions", async (t) => {
  const root = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-public-blobs-"),
  );
  t.after(() => rm(root, { recursive: true, force: true }));
  await chmod(root, 0o755);
  const store = new LocalBlobStore(root);
  await assert.rejects(
    store.put({ namespace: "media", bytes: Buffer.from("x") }),
    /must not be accessible/,
  );
  assert.equal((await stat(root)).mode & 0o777, 0o755);
});

test("different bytes at the same logical URL stay as separate blobs", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "live-dashboard-blob-versions-"));
  const index = await mkdtemp(
    path.join(os.tmpdir(), "live-dashboard-candidate-index-"),
  );
  t.after(async () => {
    await rm(root, { recursive: true, force: true });
    await rm(index, { recursive: true, force: true });
  });
  const store = new LocalBlobStore(root);
  const first = await store.put({
    namespace: "media",
    bytes: Buffer.from("image-version-a"),
  });
  const second = await store.put({
    namespace: "media",
    bytes: Buffer.from("image-version-b"),
  });
  assert.notEqual(first.sha256, second.sha256);
  assert.deepEqual(await store.read(first.key), Buffer.from("image-version-a"));
  assert.deepEqual(await store.read(second.key), Buffer.from("image-version-b"));
  const candidates = new LocalCandidateStore(index);
  await candidates.put({
    id: "same-url",
    originalURL: "https://media.example.com/approved/map.png",
    displayPolicy: "permitted_cache",
    state: "candidate",
    logicalImageID: first.sha256,
    sourceURLs: ["https://media.example.com/approved/map.png"],
    versions: [],
  });
  const loaded = await candidates.get("same-url");
  assert.equal(loaded?.state, "candidate");
  assert.equal(loaded?.displayPolicy, "permitted_cache");
  assert.equal((await candidates.list()).length, 1);
});
