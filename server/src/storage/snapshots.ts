import type { SourceSnapshot } from "../ingestion/types.js";
import type { BlobStore, StoredBlob } from "./types.js";

/** Persists the exact response bytes; callers may continue storing escaped text for review. */
export function storeSnapshotBlob(
  store: BlobStore,
  snapshot: SourceSnapshot,
): Promise<StoredBlob> {
  return store.put({
    namespace: "snapshots",
    bytes: snapshot.body,
    expectedSha256: snapshot.rawSha256,
  });
}
