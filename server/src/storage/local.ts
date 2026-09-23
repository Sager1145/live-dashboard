import { createHash, randomUUID } from "node:crypto";
import {
  access,
  chmod,
  mkdir,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import path from "node:path";
import type {
  BlobNamespace,
  BlobStore,
  PutBlobInput,
  StoredBlob,
} from "./types.js";

const SHA256 = /^[a-f0-9]{64}$/;
const KEY = /^(snapshots|media)\/sha256\/([a-f0-9]{2})\/([a-f0-9]{64})$/;

/** Disk-backed development store. Directories are private and objects are read/write only by their owner. */
export class LocalBlobStore implements BlobStore {
  readonly root: string;
  private initialized?: Promise<void>;

  constructor(root: string) {
    if (!root.trim()) throw new Error("blob root is required");
    this.root = path.resolve(root);
  }

  async put(input: PutBlobInput): Promise<StoredBlob> {
    const sha256 = createHash("sha256").update(input.bytes).digest("hex");
    if (input.expectedSha256 !== undefined && input.expectedSha256 !== sha256)
      throw new Error("blob SHA-256 does not match expected digest");
    const key = blobKey(input.namespace, sha256);
    const target = this.pathFor(key);
    const directory = path.dirname(target);
    await this.ensurePrivateDirectory(directory);
    let validExisting = false;
    if (await exists(target)) {
      try {
        await this.read(key);
        validExisting = true;
      } catch {
        validExisting = false;
      }
    }
    if (!validExisting) {
      const temporary = path.join(directory, `.${sha256}.${randomUUID()}.tmp`);
      try {
        await writeFile(temporary, input.bytes, { flag: "wx", mode: 0o600 });
        await rename(temporary, target);
        await chmod(target, 0o600);
      } catch (error) {
        await unlink(temporary).catch(() => undefined);
        try {
          await this.read(key);
        } catch {
          throw error;
        }
      }
    }
    return { key, sha256, byteSize: input.bytes.length };
  }

  async read(key: string): Promise<Buffer> {
    await (this.initialized ??= this.initializeRoot());
    const bytes = await readFile(this.pathFor(key));
    const expected = KEY.exec(key)?.[3];
    const actual = createHash("sha256").update(bytes).digest("hex");
    if (!expected || actual !== expected)
      throw new Error("blob content does not match its content-address key");
    return bytes;
  }

  async has(key: string): Promise<boolean> {
    await (this.initialized ??= this.initializeRoot());
    return exists(this.pathFor(key));
  }

  private pathFor(key: string): string {
    const match = KEY.exec(key);
    if (!match || match[2] !== match[3]!.slice(0, 2))
      throw new Error("invalid blob key");
    return path.join(this.root, ...key.split("/"));
  }

  private async ensurePrivateDirectory(directory: string): Promise<void> {
    await (this.initialized ??= this.initializeRoot());
    await mkdir(directory, { recursive: true, mode: 0o700 });
    // mkdir's mode is affected by umask; enforce permissions only on store-owned descendants.
    let current = directory;
    while (current !== this.root) {
      await chmod(current, 0o700);
      current = path.dirname(current);
    }
  }

  private async initializeRoot(): Promise<void> {
    try {
      const metadata = await stat(this.root);
      if (!metadata.isDirectory())
        throw new Error("blob root is not a directory");
      if ((metadata.mode & 0o077) !== 0)
        throw new Error(
          "existing blob root must not be accessible by group or other users",
        );
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      await mkdir(this.root, { recursive: true, mode: 0o700 });
      await chmod(this.root, 0o700);
    }
  }
}

export function blobKey(namespace: BlobNamespace, sha256: string): string {
  if (!SHA256.test(sha256)) throw new Error("invalid SHA-256 digest");
  return `${namespace}/sha256/${sha256.slice(0, 2)}/${sha256}`;
}

async function exists(filename: string): Promise<boolean> {
  try {
    await access(filename);
    return true;
  } catch {
    return false;
  }
}
