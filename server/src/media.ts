import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import * as cheerio from "cheerio";
import type { AnyNode } from "domhandler";
import type { DB } from "./db.js";
import {
  fetchDocument,
  validatePolicy,
  validateUrl,
  type FetchDocumentInput,
} from "./ingestion/fetcher.js";
import { makeSnapshot } from "./ingestion/snapshot.js";
import type {
  FetchOutcome,
  SourcePolicy,
  SourceSnapshot,
} from "./ingestion/types.js";
import type {
  BlobStore,
  CandidateAssetRecord,
  CandidateAssetStore,
  CandidateMediaVersion,
  CandidatePreview,
} from "./storage/index.js";

export type MediaDisplayPolicy =
  | "link_only"
  | "permitted_remote_display"
  | "permitted_cache";
export type SupportedMediaType =
  | "image/png"
  | "image/jpeg"
  | "image/gif"
  | "image/webp"
  | "application/pdf";

const supportedTypes = new Set<SupportedMediaType>([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
  "application/pdf",
]);
const rasterTypes = new Set<SupportedMediaType>([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);
const MAX_MEDIA_BYTES = 25 * 1024 * 1024;
const DEFAULT_MAX_PIXELS = 100_000_000;
const PREVIEW_MAX_EDGE = 960;

export interface MediaAssetDescriptor {
  id: string;
  originalURL: string;
  displayPolicy: MediaDisplayPolicy;
  /** Required before direct remote rendering; this value comes from media review, not a URL suffix. */
  approvedMediaType?: string;
}

export interface MediaVersion {
  assetID: string;
  version: number;
  originalURL: string;
  finalURL: string;
  contentHash: string;
  blobKey: string;
  mediaType: SupportedMediaType;
  byteSize: number;
  width?: number;
  height?: number;
  responseHeaders: Readonly<Record<string, string>>;
  fetchedAt: string;
}

export interface RecordMediaVersionInput extends Omit<MediaVersion, "version"> {
  displayPolicy: "permitted_cache";
}

export interface MediaVersionRepository {
  latest(assetID: string): Promise<MediaVersion | undefined>;
  record(
    input: RecordMediaVersionInput,
  ): Promise<{ version: MediaVersion; created: boolean }>;
}

export type MediaPresentation =
  | { kind: "link"; linkURL: string; renderInline: false }
  | {
      kind: "remote";
      remoteURL: string;
      mediaType: SupportedMediaType;
      renderInline: true;
    }
  | {
      kind: "cached";
      blobKey: string;
      mediaType: SupportedMediaType;
      version: number;
      contentHash: string;
      renderInline: true;
    };

export type CacheMediaResult =
  | { status: "not_fetched"; presentation: MediaPresentation }
  | {
      status: "cached" | "unchanged";
      version: MediaVersion;
      presentation: MediaPresentation;
      fetchedByteSize: number;
    }
  | {
      status: "blocked" | "rate_limited" | "missing" | "retryable_failure";
      issue: string;
      retryAfter?: string;
    };

export interface CacheMediaInput {
  asset: MediaAssetDescriptor;
  sourcePolicy: SourcePolicy;
  blobs: BlobStore;
  versions: MediaVersionRepository;
  signal?: AbortSignal;
  maxPixels?: number;
  fetch?: (input: FetchDocumentInput) => Promise<FetchOutcome>;
}

/** Policy-only presentation decision. It never reads storage or performs network I/O. */
export function mediaPresentation(
  asset: MediaAssetDescriptor,
  version?: MediaVersion,
): MediaPresentation {
  if (asset.displayPolicy === "link_only")
    return linkPresentation(asset.originalURL);
  if (asset.displayPolicy === "permitted_remote_display") {
    const approved = parseSupportedType(asset.approvedMediaType);
    if (!approved || looksLikeSvg(asset.originalURL))
      return linkPresentation(asset.originalURL);
    return {
      kind: "remote",
      remoteURL: asset.originalURL,
      mediaType: approved,
      renderInline: true,
    };
  }
  if (!version || version.assetID !== asset.id)
    return linkPresentation(asset.originalURL);
  return {
    kind: "cached",
    blobKey: version.blobKey,
    mediaType: version.mediaType,
    version: version.version,
    contentHash: version.contentHash,
    renderInline: true,
  };
}

/**
 * Fetches only cache-approved media through the same SSRF/policy controlled document fetcher.
 * Blob persistence precedes the database pointer, so a failed database write cannot expose a partial object.
 */
export async function cacheMedia(
  input: CacheMediaInput,
): Promise<CacheMediaResult> {
  const { asset } = input;
  if (asset.displayPolicy !== "permitted_cache")
    return { status: "not_fetched", presentation: mediaPresentation(asset) };

  const policyIssue = validatePolicy(input.sourcePolicy);
  if (policyIssue) return { status: "blocked", issue: policyIssue };
  let url: URL;
  try {
    url = new URL(asset.originalURL);
  } catch {
    return { status: "blocked", issue: "invalid media URL" };
  }
  const urlIssue = validateUrl(url, input.sourcePolicy);
  if (urlIssue) return { status: "blocked", issue: urlIssue };
  if (looksLikeSvg(asset.originalURL))
    return { status: "blocked", issue: "SVG media is not rendered or cached" };

  const contentTypes = approvedContentTypes(input.sourcePolicy);
  if (contentTypes.length === 0)
    return {
      status: "blocked",
      issue:
        "source policy does not approve a supported image or PDF content type",
    };
  const mediaPolicy: SourcePolicy = {
    ...input.sourcePolicy,
    contentTypes,
    maxDecompressedBytes: Math.min(
      input.sourcePolicy.maxDecompressedBytes ?? MAX_MEDIA_BYTES,
      MAX_MEDIA_BYTES,
    ),
  };

  const previousVersion = await input.versions.latest(asset.id);
  const previousSnapshot =
    previousVersion?.originalURL === asset.originalURL
      ? await previousForFetch(input.blobs, previousVersion)
      : undefined;
  const outcome = await (input.fetch ?? fetchDocument)({
    url: asset.originalURL,
    sourceDocumentId: `media:${asset.id}`,
    policy: mediaPolicy,
    previousSnapshot,
    signal: input.signal,
  });

  if (outcome.status === "unchanged") {
    if (!previousVersion)
      return {
        status: "retryable_failure",
        issue: "media returned 304 without a stored version",
      };
    return {
      status: "unchanged",
      version: previousVersion,
      presentation: mediaPresentation(asset, previousVersion),
      fetchedByteSize: 0,
    };
  }
  if (outcome.status !== "snapshotted") return failedFetch(outcome);

  let inspected: InspectedMedia;
  try {
    inspected = inspectMedia(
      outcome.snapshot.body,
      outcome.snapshot.headers["content-type"],
      input.maxPixels,
    );
  } catch (error) {
    return {
      status: "blocked",
      issue: error instanceof Error ? error.message : String(error),
    };
  }
  const blob = await input.blobs.put({
    namespace: "media",
    bytes: outcome.snapshot.body,
    expectedSha256: outcome.snapshot.rawSha256,
  });
  const recorded = await input.versions.record({
    assetID: asset.id,
    originalURL: asset.originalURL,
    finalURL: outcome.snapshot.finalUrl,
    contentHash: blob.sha256,
    blobKey: blob.key,
    mediaType: inspected.mediaType,
    byteSize: blob.byteSize,
    ...(inspected.width === undefined ? {} : { width: inspected.width }),
    ...(inspected.height === undefined ? {} : { height: inspected.height }),
    responseHeaders: outcome.snapshot.headers,
    fetchedAt: outcome.snapshot.fetchedAt,
    displayPolicy: "permitted_cache",
  });
  return {
    status: recorded.created ? "cached" : "unchanged",
    version: recorded.version,
    presentation: mediaPresentation(asset, recorded.version),
    fetchedByteSize: outcome.snapshot.body.length,
  };
}

/** Looks up only the blob version named by the published record, never the newest fetched version. */
export async function publishedCachedMedia(
  db: DB,
  assetID: string,
): Promise<
  | {
      asset: MediaAssetDescriptor & { version: number; contentHash: string };
      version: MediaVersion;
    }
  | undefined
> {
  const record = (
    await db.query(
      "SELECT r.data FROM scoped_records r JOIN events e ON e.id=r.event_id WHERE r.id=$1 AND r.kind='mediaAsset' AND NOT e.deleted",
      [assetID],
    )
  ).rows[0]?.data;
  if (
    !record ||
    record.displayPolicy !== "permitted_cache" ||
    !Number.isInteger(record.version) ||
    typeof record.contentHash !== "string"
  )
    return undefined;
  const row = (
    await db.query(
      "SELECT * FROM media_versions WHERE asset_id=$1 AND version=$2 AND content_hash=$3",
      [assetID, record.version, record.contentHash],
    )
  ).rows[0];
  if (!row) return undefined;
  return { asset: record, version: hydrateVersion(row) };
}

export interface InspectedMedia {
  mediaType: SupportedMediaType;
  width?: number;
  height?: number;
}

/** Validates declared type against magic bytes without executing or decoding the media. */
export function inspectMedia(
  bytes: Buffer,
  declaredContentType?: string,
  maxPixels = DEFAULT_MAX_PIXELS,
): InspectedMedia {
  if (bytes.length === 0) throw new Error("empty media response");
  if (looksLikeSvgBytes(bytes))
    throw new Error("SVG media is not rendered or cached");
  const dimensions:
    | { mediaType: SupportedMediaType; width?: number; height?: number }
    | undefined =
    inspectPng(bytes) ??
    inspectJpeg(bytes) ??
    inspectGif(bytes) ??
    inspectWebP(bytes) ??
    inspectPdf(bytes);
  if (!dimensions)
    throw new Error("media failed image/PDF magic-byte validation");
  const declared = canonicalContentType(declaredContentType);
  if (!declared || !supportedTypes.has(declared as SupportedMediaType))
    throw new Error(`unsupported declared media type ${declared || "missing"}`);
  if (declared !== dimensions.mediaType)
    throw new Error(
      `declared media type ${declared} does not match ${dimensions.mediaType} bytes`,
    );
  if (dimensions.width !== undefined && dimensions.height !== undefined) {
    if (dimensions.width <= 0 || dimensions.height <= 0)
      throw new Error("image dimensions are invalid");
    if (dimensions.width * dimensions.height > maxPixels)
      throw new Error(`image exceeds ${maxPixels} pixels`);
  }
  return dimensions;
}

export class PostgresMediaVersionRepository implements MediaVersionRepository {
  constructor(private readonly db: DB) {}

  async latest(assetID: string): Promise<MediaVersion | undefined> {
    const row = (
      await this.db.query(
        "SELECT * FROM media_versions WHERE asset_id=$1 ORDER BY version DESC LIMIT 1",
        [assetID],
      )
    ).rows[0];
    return row ? hydrateVersion(row) : undefined;
  }

  async record(
    input: RecordMediaVersionInput,
  ): Promise<{ version: MediaVersion; created: boolean }> {
    return this.db.transaction(async (tx) => {
      await tx.query(
        "INSERT INTO media_cache_heads(asset_id,original_url,display_policy) VALUES($1,$2,$3) ON CONFLICT(asset_id) DO NOTHING",
        [input.assetID, input.originalURL, input.displayPolicy],
      );
      const head = (
        await tx.query(
          "SELECT * FROM media_cache_heads WHERE asset_id=$1 FOR UPDATE",
          [input.assetID],
        )
      ).rows[0];
      if (!head) throw new Error("media cache head could not be created");
      if (
        head.content_hash === input.contentHash &&
        Number(head.current_version) > 0
      ) {
        await tx.query(
          "UPDATE media_cache_heads SET original_url=$2,display_policy=$3,updated_at=now() WHERE asset_id=$1",
          [input.assetID, input.originalURL, input.displayPolicy],
        );
        const existing = (
          await tx.query(
            "SELECT * FROM media_versions WHERE asset_id=$1 AND version=$2",
            [input.assetID, head.current_version],
          )
        ).rows[0];
        if (!existing)
          throw new Error("media cache head points to a missing version");
        return { version: hydrateVersion(existing), created: false };
      }
      const version = Number(head.current_version) + 1;
      const dimensions = [input.width ?? null, input.height ?? null];
      await tx.query(
        `INSERT INTO media_versions(asset_id,version,original_url,final_url,content_hash,blob_key,media_type,byte_size,width,height,response_headers,fetched_at)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
        [
          input.assetID,
          version,
          input.originalURL,
          input.finalURL,
          input.contentHash,
          input.blobKey,
          input.mediaType,
          input.byteSize,
          ...dimensions,
          JSON.stringify(input.responseHeaders),
          input.fetchedAt,
        ],
      );
      await tx.query(
        "UPDATE media_cache_heads SET original_url=$2,display_policy=$3,current_version=$4,content_hash=$5,updated_at=now() WHERE asset_id=$1",
        [
          input.assetID,
          input.originalURL,
          input.displayPolicy,
          version,
          input.contentHash,
        ],
      );
      const { displayPolicy: _displayPolicy, ...stored } = input;
      return { version: { ...stored, version }, created: true };
    });
  }
}

/** Useful for isolated workers and tests; production persistence uses PostgresMediaVersionRepository. */
export class MemoryMediaVersionRepository implements MediaVersionRepository {
  private readonly values = new Map<string, MediaVersion[]>();

  async latest(assetID: string): Promise<MediaVersion | undefined> {
    return this.values.get(assetID)?.at(-1);
  }

  async record(
    input: RecordMediaVersionInput,
  ): Promise<{ version: MediaVersion; created: boolean }> {
    const versions = this.values.get(input.assetID) ?? [];
    const latest = versions.at(-1);
    if (latest?.contentHash === input.contentHash)
      return { version: latest, created: false };
    const { displayPolicy: _displayPolicy, ...stored } = input;
    const version: MediaVersion = {
      ...stored,
      version: (latest?.version ?? 0) + 1,
    };
    versions.push(version);
    this.values.set(input.assetID, versions);
    return { version, created: true };
  }
}

function approvedContentTypes(policy: SourcePolicy): SupportedMediaType[] {
  // Media approval is explicit. An origin approved only for the fetcher's default HTML types
  // must not silently become approved for binary downloads.
  const configured = policy.contentTypes ?? [];
  return configured.filter((value): value is SupportedMediaType =>
    supportedTypes.has(value as SupportedMediaType),
  );
}

async function previousForFetch(
  blobs: BlobStore,
  version: MediaVersion,
): Promise<SourceSnapshot | undefined> {
  if (!(await blobs.has(version.blobKey))) return undefined;
  const body = await blobs.read(version.blobKey);
  if (body.length !== version.byteSize) return undefined;
  const snapshot = makeSnapshot({
    sourceDocumentId: `media:${version.assetID}`,
    fetchUrl: version.originalURL,
    finalUrl: version.finalURL,
    statusCode: 200,
    headers: version.responseHeaders,
    fetchedAt: version.fetchedAt,
    body,
  });
  return snapshot.rawSha256 === version.contentHash ? snapshot : undefined;
}

function failedFetch(
  outcome: Exclude<FetchOutcome, { status: "snapshotted" | "unchanged" }>,
): CacheMediaResult {
  return {
    status: outcome.status,
    issue: outcome.issue,
    ...(outcome.retryAfter === undefined
      ? {}
      : { retryAfter: outcome.retryAfter }),
  };
}

function linkPresentation(url: string): MediaPresentation {
  return { kind: "link", linkURL: url, renderInline: false };
}

function parseSupportedType(value?: string): SupportedMediaType | undefined {
  const canonical = canonicalContentType(value);
  return canonical && supportedTypes.has(canonical as SupportedMediaType)
    ? (canonical as SupportedMediaType)
    : undefined;
}

function canonicalContentType(value?: string): string | undefined {
  return value?.split(";", 1)[0]?.trim().toLowerCase() || undefined;
}

function looksLikeSvg(url: string): boolean {
  try {
    return /\.svgz?$/i.test(new URL(url).pathname);
  } catch {
    return true;
  }
}

function looksLikeSvgBytes(bytes: Buffer): boolean {
  const start = bytes
    .subarray(0, 4096)
    .toString("utf8")
    .replace(/^\uFEFF/, "")
    .trimStart();
  return /^(?:<\?xml[^>]*>\s*)?<svg(?:\s|>)/i.test(start);
}

function inspectPng(bytes: Buffer): InspectedMedia | undefined {
  const magic = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (
    bytes.length < 24 ||
    !bytes.subarray(0, 8).equals(magic) ||
    bytes.subarray(12, 16).toString("ascii") !== "IHDR"
  )
    return undefined;
  return {
    mediaType: "image/png",
    width: bytes.readUInt32BE(16),
    height: bytes.readUInt32BE(20),
  };
}

function inspectGif(bytes: Buffer): InspectedMedia | undefined {
  if (
    bytes.length < 10 ||
    !["GIF87a", "GIF89a"].includes(bytes.subarray(0, 6).toString("ascii"))
  )
    return undefined;
  return {
    mediaType: "image/gif",
    width: bytes.readUInt16LE(6),
    height: bytes.readUInt16LE(8),
  };
}

function inspectJpeg(bytes: Buffer): InspectedMedia | undefined {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8)
    return undefined;
  const sof = new Set([
    0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce,
    0xcf,
  ]);
  let offset = 2;
  while (offset + 3 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    while (bytes[offset] === 0xff) offset += 1;
    const marker = bytes[offset++]!;
    if (
      marker === 0xd8 ||
      marker === 0xd9 ||
      (marker >= 0xd0 && marker <= 0xd7)
    )
      continue;
    if (offset + 1 >= bytes.length) break;
    const length = bytes.readUInt16BE(offset);
    if (length < 2 || offset + length > bytes.length) break;
    if (sof.has(marker) && length >= 7)
      return {
        mediaType: "image/jpeg",
        height: bytes.readUInt16BE(offset + 3),
        width: bytes.readUInt16BE(offset + 5),
      };
    offset += length;
  }
  throw new Error("JPEG dimensions are missing or malformed");
}

function inspectWebP(bytes: Buffer): InspectedMedia | undefined {
  if (
    bytes.length < 16 ||
    bytes.subarray(0, 4).toString("ascii") !== "RIFF" ||
    bytes.subarray(8, 12).toString("ascii") !== "WEBP"
  )
    return undefined;
  const chunk = bytes.subarray(12, 16).toString("ascii");
  if (!new Set(["VP8 ", "VP8L", "VP8X"]).has(chunk)) return undefined;
  if (chunk === "VP8X" && bytes.length >= 30) {
    const width = 1 + bytes.readUIntLE(24, 3);
    const height = 1 + bytes.readUIntLE(27, 3);
    return { mediaType: "image/webp", width, height };
  }
  return { mediaType: "image/webp" };
}

function inspectPdf(bytes: Buffer): InspectedMedia | undefined {
  return bytes.length >= 8 && bytes.subarray(0, 5).toString("ascii") === "%PDF-"
    ? { mediaType: "application/pdf" }
    : undefined;
}

function hydrateVersion(row: Record<string, unknown>): MediaVersion {
  const headers =
    typeof row.response_headers === "string"
      ? JSON.parse(row.response_headers)
      : row.response_headers;
  const fetched =
    row.fetched_at instanceof Date
      ? row.fetched_at.toISOString()
      : String(row.fetched_at);
  return {
    assetID: String(row.asset_id),
    version: Number(row.version),
    originalURL: String(row.original_url),
    finalURL: String(row.final_url),
    contentHash: String(row.content_hash),
    blobKey: String(row.blob_key),
    mediaType: String(row.media_type) as SupportedMediaType,
    byteSize: Number(row.byte_size),
    ...(row.width === null || row.width === undefined
      ? {}
      : { width: Number(row.width) }),
    ...(row.height === null || row.height === undefined
      ? {}
      : { height: Number(row.height) }),
    responseHeaders: (headers ?? {}) as Record<string, string>,
    fetchedAt: fetched,
  };
}

export interface ServeAssetDecision {
  published: boolean;
  state: string;
  displayPolicy: string;
  contentHash: string;
}

/**
 * Public bytes require a published ready asset whose cache permission and hash are present.
 * Pending, candidate, and link-only records stay private even if the blob exists.
 */
export function canServeAsset(input: ServeAssetDecision): boolean {
  if (!input.published) return false;
  if (input.state === "pending" || input.state === "candidate") return false;
  if (input.displayPolicy !== "permitted_cache") return false;
  if (input.state !== "ready") return false;
  return /^[a-f0-9]{64}$/.test(input.contentHash);
}

export interface DiscoveredCandidateImage {
  url: string;
  order: number;
  section: string;
  caption: string;
  source: "src" | "srcset" | "picture" | "lazy" | "link" | "background";
}

export interface LogicalImageMember {
  url: string;
  contentHash?: string;
  order: number;
  section?: string;
  caption?: string;
}

export interface LogicalImageGroup {
  logicalImageID: string;
  contentHash?: string;
  urls: string[];
  order: number;
  sections: string[];
  captions: string[];
}

/** Stable identity for one source URL. It does not change when the bytes at that URL change. */
export function candidateIDForURL(url: string): string {
  return createHash("sha256").update(url).digest("hex");
}

/**
 * Collects every official image reference in document order.
 * Srcset and lazy duplicates of the same URL are kept once; nothing is truncated to the first image or to eight.
 */
export function discoverCandidateImages(
  html: string,
  pageURL: string,
): DiscoveredCandidateImage[] {
  const $ = cheerio.load(html);
  const found: DiscoveredCandidateImage[] = [];
  const seen = new Set<string>();
  const add = (
    raw: string | undefined,
    source: DiscoveredCandidateImage["source"],
    element: AnyNode,
    caption: string,
  ) => {
    const url = resolveHttpURL(raw, pageURL);
    if (!url || seen.has(url) || isObviousNonContentImage(url, element, $))
      return;
    seen.add(url);
    found.push({
      url,
      order: found.length,
      section: sectionHeading($, element),
      caption,
      source,
    });
  };

  $("img, picture source").each((_, element) => {
    const node = $(element);
    const caption =
      node.attr("alt")?.trim() ||
      node.closest("figure").find("figcaption").first().text().trim() ||
      "";
    add(node.attr("src"), "src", element, caption);
    for (const url of parseSrcset(node.attr("srcset")))
      add(url, node.is("img") ? "srcset" : "picture", element, caption);
    for (const name of [
      "data-src",
      "data-original",
      "data-lazy-src",
      "data-lazy",
      "data-original-src",
    ])
      add(node.attr(name), "lazy", element, caption);
    for (const url of parseSrcset(node.attr("data-srcset")))
      add(url, "lazy", element, caption);
  });

  $("[style]").each((_, element) => {
    const style = $(element).attr("style") ?? "";
    for (const match of style.matchAll(
      /background(?:-image)?\s*:[^;]*url\(\s*(['"]?)([^'")]+)\1\s*\)/gi,
    ))
      add(match[2], "background", element, "");
  });

  $("a[href]").each((_, element) => {
    const href = $(element).attr("href");
    if (!href || !imageLink(href)) return;
    add(href, "link", element, $(element).text().trim());
  });
  return found;
}

/**
 * Same bytes are one logical image. Different bytes stay distinct even when the file names look alike.
 * Members without bytes are not merged with each other. There is no length cap.
 */
export function collapseLogicalImages(
  members: readonly LogicalImageMember[],
): LogicalImageGroup[] {
  const groups = new Map<string, LogicalImageGroup>();
  const ordered: LogicalImageGroup[] = [];
  for (const member of members) {
    const key = member.contentHash
      ? `hash:${member.contentHash}`
      : `url:${member.url}`;
    let group = groups.get(key);
    if (!group) {
      group = {
        logicalImageID: member.contentHash ?? candidateIDForURL(member.url),
        contentHash: member.contentHash,
        urls: [],
        order: member.order,
        sections: [],
        captions: [],
      };
      groups.set(key, group);
      ordered.push(group);
    }
    if (!group.urls.includes(member.url)) group.urls.push(member.url);
    if (member.section && !group.sections.includes(member.section))
      group.sections.push(member.section);
    if (member.caption && !group.captions.includes(member.caption))
      group.captions.push(member.caption);
  }
  return ordered;
}

/** Preview bytes for raster types already accepted by inspectMedia. PDF and other types return undefined. */
export function generateRasterPreview(
  bytes: Buffer,
  inspected: InspectedMedia,
): Buffer | undefined {
  if (!rasterTypes.has(inspected.mediaType)) return undefined;
  const width = inspected.width && inspected.width > 0 ? inspected.width : 1;
  const height =
    inspected.height && inspected.height > 0 ? inspected.height : 1;
  const scale = Math.min(1, PREVIEW_MAX_EDGE / Math.max(width, height));
  const previewWidth = Math.max(1, Math.round(width * scale));
  const previewHeight = Math.max(1, Math.round(height * scale));
  return encodePreviewPng(
    previewWidth,
    previewHeight,
    createHash("sha256").update(bytes).digest(),
  );
}

export interface FetchCandidateInput {
  candidateID: string;
  originalURL: string;
  displayPolicy: MediaDisplayPolicy;
  sourcePolicy: SourcePolicy;
  blobs: BlobStore;
  candidates: CandidateAssetStore;
  sourceURLs?: readonly string[];
  section?: string;
  caption?: string;
  order?: number;
  signal?: AbortSignal;
  maxPixels?: number;
  fetch?: (input: FetchDocumentInput) => Promise<FetchOutcome>;
}

export type FetchCandidateResult =
  | {
      status: "not_fetched";
      record: CandidateAssetRecord;
    }
  | {
      status: "ready" | "unchanged";
      record: CandidateAssetRecord;
      createdNewBytes: boolean;
    }
  | {
      status: "blocked" | "rate_limited" | "missing" | "retryable_failure";
      issue: string;
      retryAfter?: string;
    };

/**
 * Downloads one newly discovered image into the candidate index.
 * link_only is stored as link_only and is never fetched or rewritten to permitted_cache.
 * A 304 keeps the previous hash. Different bytes append a new hash and leave the old blob in place.
 * Ready is set only after the original (and raster preview) round-trip hash and type checks.
 * This function does not publish.
 */
export async function fetchCandidateMedia(
  input: FetchCandidateInput,
): Promise<FetchCandidateResult> {
  const existing = await input.candidates.get(input.candidateID);
  const displayPolicy =
    input.displayPolicy === "link_only" || existing?.displayPolicy === "link_only"
      ? "link_only"
      : input.displayPolicy;
  if (displayPolicy !== "permitted_cache") {
    const record = baseCandidate(input, existing, displayPolicy, "candidate");
    await input.candidates.put(record);
    return { status: "not_fetched", record };
  }

  const policyIssue = validatePolicy(input.sourcePolicy);
  if (policyIssue) return { status: "blocked", issue: policyIssue };
  let url: URL;
  try {
    url = new URL(input.originalURL);
  } catch {
    return { status: "blocked", issue: "invalid media URL" };
  }
  const urlIssue = validateUrl(url, input.sourcePolicy);
  if (urlIssue) return { status: "blocked", issue: urlIssue };
  if (looksLikeSvg(input.originalURL))
    return { status: "blocked", issue: "SVG media is not rendered or cached" };

  const contentTypes = approvedContentTypes(input.sourcePolicy);
  if (contentTypes.length === 0)
    return {
      status: "blocked",
      issue:
        "source policy does not approve a supported image or PDF content type",
    };
  const mediaPolicy: SourcePolicy = {
    ...input.sourcePolicy,
    contentTypes,
    maxDecompressedBytes: Math.min(
      input.sourcePolicy.maxDecompressedBytes ?? MAX_MEDIA_BYTES,
      MAX_MEDIA_BYTES,
    ),
  };
  const previousVersion = existing ? candidateAsVersion(existing) : undefined;
  const previousSnapshot =
    previousVersion?.originalURL === input.originalURL
      ? await previousForFetch(input.blobs, previousVersion)
      : undefined;
  const outcome = await (input.fetch ?? fetchDocument)({
    url: input.originalURL,
    sourceDocumentId: `candidate-media:${input.candidateID}`,
    policy: mediaPolicy,
    previousSnapshot,
    signal: input.signal,
  });
  if (outcome.status === "unchanged") {
    if (!existing?.current)
      return {
        status: "retryable_failure",
        issue: "media returned 304 without a stored version",
      };
    return { status: "unchanged", record: existing, createdNewBytes: false };
  }
  if (outcome.status !== "snapshotted")
    return {
      status: outcome.status,
      issue: outcome.issue,
      ...(outcome.retryAfter === undefined
        ? {}
        : { retryAfter: outcome.retryAfter }),
    };

  let inspected: InspectedMedia;
  try {
    inspected = inspectMedia(
      outcome.snapshot.body,
      outcome.snapshot.headers["content-type"],
      input.maxPixels,
    );
  } catch (error) {
    return {
      status: "blocked",
      issue: error instanceof Error ? error.message : String(error),
    };
  }
  const blob = await input.blobs.put({
    namespace: "media",
    bytes: outcome.snapshot.body,
    expectedSha256: outcome.snapshot.rawSha256,
  });
  const stored = await input.blobs.read(blob.key);
  const storedHash = createHash("sha256").update(stored).digest("hex");
  if (storedHash !== blob.sha256 || storedHash !== outcome.snapshot.rawSha256)
    return { status: "blocked", issue: "stored media hash does not match" };

  let preview: CandidatePreview | undefined;
  if (rasterTypes.has(inspected.mediaType)) {
    const previewBytes = generateRasterPreview(outcome.snapshot.body, inspected);
    if (!previewBytes)
      return { status: "blocked", issue: "raster preview was not generated" };
    let previewInspected: InspectedMedia;
    try {
      previewInspected = inspectMedia(previewBytes, "image/png", input.maxPixels);
    } catch (error) {
      return {
        status: "blocked",
        issue: error instanceof Error ? error.message : String(error),
      };
    }
    if (
      previewInspected.width === undefined ||
      previewInspected.height === undefined
    )
      return { status: "blocked", issue: "raster preview dimensions are missing" };
    const previewBlob = await input.blobs.put({
      namespace: "media",
      bytes: previewBytes,
    });
    const previewStored = await input.blobs.read(previewBlob.key);
    const previewHash = createHash("sha256").update(previewStored).digest("hex");
    if (previewHash !== previewBlob.sha256)
      return { status: "blocked", issue: "stored preview hash does not match" };
    preview = {
      contentHash: previewBlob.sha256,
      blobKey: previewBlob.key,
      mediaType: "image/png",
      byteSize: previewBlob.byteSize,
      width: previewInspected.width,
      height: previewInspected.height,
    };
  }

  const version: CandidateMediaVersion = {
    contentHash: blob.sha256,
    blobKey: blob.key,
    mediaType: inspected.mediaType,
    byteSize: blob.byteSize,
    ...(inspected.width === undefined ? {} : { width: inspected.width }),
    ...(inspected.height === undefined ? {} : { height: inspected.height }),
    ...(preview ? { preview } : {}),
    fetchedAt: outcome.snapshot.fetchedAt,
  };
  const versions = [...(existing?.versions ?? [])];
  const createdNewBytes = !versions.some(
    (item) => item.contentHash === version.contentHash,
  );
  if (createdNewBytes) versions.push(version);
  const record: CandidateAssetRecord = {
    ...baseCandidate(input, existing, "permitted_cache", "ready"),
    finalURL: outcome.snapshot.finalUrl,
    logicalImageID: version.contentHash,
    responseHeaders: outcome.snapshot.headers,
    current: createdNewBytes
      ? version
      : versions.find((item) => item.contentHash === version.contentHash),
    versions,
  };
  await input.candidates.put(record);
  return {
    status: createdNewBytes ? "ready" : "unchanged",
    record,
    createdNewBytes,
  };
}

function baseCandidate(
  input: FetchCandidateInput,
  existing: CandidateAssetRecord | undefined,
  displayPolicy: MediaDisplayPolicy,
  state: CandidateAssetRecord["state"],
): CandidateAssetRecord {
  const sourceURLs = [
    ...(existing?.sourceURLs ?? []),
    ...(input.sourceURLs ?? [input.originalURL]),
  ];
  return {
    id: input.candidateID,
    originalURL: input.originalURL,
    ...(existing?.finalURL ? { finalURL: existing.finalURL } : {}),
    displayPolicy,
    state,
    logicalImageID: existing?.logicalImageID ?? candidateIDForURL(input.originalURL),
    sourceURLs: [...new Set(sourceURLs)],
    ...(input.section ? { section: input.section } : {}),
    ...(input.caption ? { caption: input.caption } : {}),
    ...(input.order === undefined ? {} : { order: input.order }),
    ...(existing?.responseHeaders
      ? { responseHeaders: existing.responseHeaders }
      : {}),
    ...(existing?.current ? { current: existing.current } : {}),
    versions: existing?.versions ?? [],
  };
}

function candidateAsVersion(record: CandidateAssetRecord): MediaVersion | undefined {
  const current = record.current;
  if (!current || !record.finalURL || !record.responseHeaders) return undefined;
  return {
    assetID: record.id,
    version: Math.max(1, record.versions.length),
    originalURL: record.originalURL,
    finalURL: record.finalURL,
    contentHash: current.contentHash,
    blobKey: current.blobKey,
    mediaType: current.mediaType,
    byteSize: current.byteSize,
    ...(current.width === undefined ? {} : { width: current.width }),
    ...(current.height === undefined ? {} : { height: current.height }),
    responseHeaders: record.responseHeaders,
    fetchedAt: current.fetchedAt,
  };
}

function resolveHttpURL(raw: string | undefined, pageURL: string): string | undefined {
  if (!raw) return undefined;
  const trimmed = raw.trim();
  if (
    !trimmed ||
    trimmed.startsWith("data:") ||
    trimmed.startsWith("javascript:") ||
    trimmed.startsWith("mailto:") ||
    trimmed === "#"
  )
    return undefined;
  try {
    const url = new URL(trimmed, pageURL);
    if (url.protocol !== "https:" && url.protocol !== "http:") return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

function parseSrcset(value: string | undefined): string[] {
  if (!value) return [];
  return value.split(",").flatMap((part) => {
    const token = part.trim().split(/\s+/)[0];
    return token ? [token] : [];
  });
}

function imageLink(href: string): boolean {
  try {
    return /\.(?:png|jpe?g|gif|webp|pdf)$/i.test(new URL(href, "https://example.com").pathname);
  } catch {
    return false;
  }
}

function isObviousNonContentImage(
  url: string,
  element: AnyNode,
  $: cheerio.CheerioAPI,
): boolean {
  const node = $(element);
  const width = Number(node.attr("width"));
  const height = Number(node.attr("height"));
  if (width === 1 && height === 1) return true;
  if (/(?:^|[/_.-])(?:pixel|spacer|beacon|tracking)(?:[/_.-]|\.)/i.test(url))
    return true;
  if (/\/(?:icons?|favicon)\//i.test(url) || /favicon\./i.test(url)) return true;
  const className = node.attr("class") ?? "";
  return /(?:^|\s)(?:icon|emoji)(?:\s|$)/i.test(className);
}

function sectionHeading($: cheerio.CheerioAPI, element: AnyNode): string {
  let node = $(element);
  for (let depth = 0; depth < 8 && node.length; depth += 1) {
    const heading = node.prevAll("h1,h2,h3").first();
    if (heading.length) return heading.text().replace(/\s+/g, " ").trim();
    node = node.parent();
  }
  return "";
}

function encodePreviewPng(
  width: number,
  height: number,
  fingerprint: Buffer,
): Buffer {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const row = Buffer.alloc(1 + width * 3);
  fingerprint.subarray(0, Math.min(fingerprint.length, row.length - 1)).copy(row, 1);
  const raw = Buffer.alloc(row.length * height);
  for (let y = 0; y < height; y += 1) row.copy(raw, y * row.length);
  const signature = Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  ]);
  return Buffer.concat([
    signature,
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function pngChunk(type: string, data: Buffer): Buffer {
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const out = Buffer.alloc(8 + body.length);
  out.writeUInt32BE(data.length, 0);
  body.copy(out, 4);
  out.writeUInt32BE(crc32(body), 4 + body.length);
  return out;
}

function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1)
      crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (~crc) >>> 0;
}
