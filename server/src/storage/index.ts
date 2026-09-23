import { LocalBlobStore } from "./local.js";

export * from "./types.js";
export * from "./local.js";
export * from "./snapshots.js";

/** Returns no store when blob persistence was not configured. It never chooses a public directory. */
export function blobStoreFromEnv(
  env: Readonly<Record<string, string | undefined>> = process.env,
): LocalBlobStore | undefined {
  const root = env.BLOB_ROOT?.trim();
  return root ? new LocalBlobStore(root) : undefined;
}
