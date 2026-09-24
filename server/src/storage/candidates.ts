import { createHash, randomUUID } from "node:crypto";
import { chmod, mkdir, readdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

export type CandidateDisplayPolicy =
  | "link_only"
  | "permitted_remote_display"
  | "permitted_cache";

export type CandidateMediaType =
  | "image/png"
  | "image/jpeg"
  | "image/gif"
  | "image/webp"
  | "application/pdf";

/** Public serving treats pending and candidate as not downloadable. */
export type CandidateState = "pending" | "candidate" | "ready" | "withdrawn";

export interface CandidatePreview {
  contentHash: string;
  blobKey: string;
  mediaType: "image/png";
  byteSize: number;
  width: number;
  height: number;
}

/** One immutable byte version. A later hash is appended; nothing here deletes the previous blob. */
export interface CandidateMediaVersion {
  contentHash: string;
  blobKey: string;
  mediaType: CandidateMediaType;
  byteSize: number;
  width?: number;
  height?: number;
  preview?: CandidatePreview;
  fetchedAt: string;
}

export interface CandidateAssetRecord {
  id: string;
  originalURL: string;
  finalURL?: string;
  displayPolicy: CandidateDisplayPolicy;
  state: CandidateState;
  logicalImageID: string;
  sourceURLs: string[];
  section?: string;
  caption?: string;
  order?: number;
  responseHeaders?: Readonly<Record<string, string>>;
  current?: CandidateMediaVersion;
  versions: CandidateMediaVersion[];
}

/** Private candidate index. It is not a public content path and does not store bytes. */
export interface CandidateAssetStore {
  get(id: string): Promise<CandidateAssetRecord | undefined>;
  put(record: CandidateAssetRecord): Promise<void>;
  list(): Promise<CandidateAssetRecord[]>;
}

export class MemoryCandidateStore implements CandidateAssetStore {
  private readonly records = new Map<string, CandidateAssetRecord>();

  async get(id: string): Promise<CandidateAssetRecord | undefined> {
    const record = this.records.get(id);
    return record ? structuredClone(record) : undefined;
  }

  async put(record: CandidateAssetRecord): Promise<void> {
    this.records.set(record.id, structuredClone(record));
  }

  async list(): Promise<CandidateAssetRecord[]> {
    return [...this.records.values()].map((record) => structuredClone(record));
  }
}

/** Disk index beside the blob root. Bytes stay in the content-addressed blob store. */
export class LocalCandidateStore implements CandidateAssetStore {
  readonly root: string;
  private initialized?: Promise<void>;

  constructor(root: string) {
    if (!root.trim()) throw new Error("candidate root is required");
    this.root = path.resolve(root);
  }

  async get(id: string): Promise<CandidateAssetRecord | undefined> {
    await this.ready();
    try {
      return JSON.parse(await readFile(this.pathFor(id), "utf8")) as CandidateAssetRecord;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw error;
    }
  }

  async put(record: CandidateAssetRecord): Promise<void> {
    await this.ready();
    const target = this.pathFor(record.id);
    await mkdir(path.dirname(target), { recursive: true, mode: 0o700 });
    await chmod(path.dirname(target), 0o700);
    const temporary = path.join(
      path.dirname(target),
      `.${randomUUID()}.tmp`,
    );
    try {
      await writeFile(temporary, JSON.stringify(record), {
        flag: "wx",
        mode: 0o600,
      });
      await rename(temporary, target);
      await chmod(target, 0o600);
    } catch (error) {
      await unlink(temporary).catch(() => undefined);
      throw error;
    }
  }

  async list(): Promise<CandidateAssetRecord[]> {
    await this.ready();
    const records: CandidateAssetRecord[] = [];
    const shards = await readdir(this.root).catch(() => [] as string[]);
    for (const shard of shards) {
      if (!/^[a-f0-9]{2}$/.test(shard)) continue;
      const names = await readdir(path.join(this.root, shard));
      for (const name of names) {
        if (!name.endsWith(".json")) continue;
        const parsed = JSON.parse(
          await readFile(path.join(this.root, shard, name), "utf8"),
        ) as CandidateAssetRecord;
        records.push(parsed);
      }
    }
    return records;
  }

  private async ready(): Promise<void> {
    await (this.initialized ??= this.initializeRoot());
  }

  private pathFor(id: string): string {
    if (!id || id.includes("\0")) throw new Error("invalid candidate id");
    const digest = createHash("sha256").update(id).digest("hex");
    return path.join(this.root, digest.slice(0, 2), `${digest}.json`);
  }

  private async initializeRoot(): Promise<void> {
    await mkdir(this.root, { recursive: true, mode: 0o700 });
    await chmod(this.root, 0o700);
  }
}
