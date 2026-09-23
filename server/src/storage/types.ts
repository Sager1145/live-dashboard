export type BlobNamespace = "snapshots" | "media";

export interface PutBlobInput {
  namespace: BlobNamespace;
  bytes: Buffer;
  /** Rejects a caller/storage mismatch instead of writing under an unexpected digest. */
  expectedSha256?: string;
}

export interface StoredBlob {
  key: string;
  sha256: string;
  byteSize: number;
}

/**
 * Private binary storage. Keys are opaque to callers and never imply a public URL.
 * Implementations must make put idempotent for identical namespace + bytes.
 */
export interface BlobStore {
  put(input: PutBlobInput): Promise<StoredBlob>;
  read(key: string): Promise<Buffer>;
  has(key: string): Promise<boolean>;
}
