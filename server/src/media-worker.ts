import type { Bundle } from "./contracts.js";
import type { DB } from "./db.js";
import type { FetchDocumentInput } from "./ingestion/fetcher.js";
import type { FetchOutcome, SourcePolicy } from "./ingestion/types.js";
import {
  cacheMedia,
  candidateIDForURL,
  discoverCandidateImages,
  fetchCandidateMedia,
  PostgresMediaVersionRepository,
  type CacheMediaResult,
  type FetchCandidateResult,
  type MediaAssetDescriptor,
  type MediaDisplayPolicy,
} from "./media.js";
import { createReview } from "./publisher.js";
import { claim, complete, enqueue, fail } from "./queue.js";
import type { BlobStore, CandidateAssetStore } from "./storage/index.js";

const JOB_KIND = "media.fetch";
const CANDIDATE_JOB_KIND = "candidate.media.fetch";
const MINIMUM_REFRESH_SECONDS = 6 * 60 * 60;
const LEASE_SECONDS = 180;

export interface ScheduleMediaOptions {
  now?: Date;
  refreshIntervalSeconds?: number;
  limit?: number;
}

export interface RunMediaJobOptions {
  blobs: BlobStore;
  fetch?: (input: FetchDocumentInput) => Promise<FetchOutcome>;
}

interface PublishedMediaRow {
  eventID: string;
  revision: number;
  bundle: Bundle;
  asset: MediaAssetDescriptor & { version: number; contentHash?: string };
}

/** Schedules only published, cache-approved assets whose separately approved origin is due. */
export async function scheduleMedia(
  db: DB,
  options: ScheduleMediaOptions = {},
): Promise<number> {
  const now = options.now ?? new Date();
  const refreshSeconds = Math.max(
    MINIMUM_REFRESH_SECONDS,
    options.refreshIntervalSeconds ?? MINIMUM_REFRESH_SECONDS,
  );
  const limit = Math.max(1, Math.min(500, options.limit ?? 100));
  const rows = (
    await db.query(
      `SELECT r.id,r.data,e.id AS event_id,e.revision,h.current_version,v.fetched_at
       FROM scoped_records r
       JOIN events e ON e.id=r.event_id AND NOT e.deleted
       LEFT JOIN media_cache_heads h ON h.asset_id=r.id
       LEFT JOIN media_versions v ON v.asset_id=h.asset_id AND v.version=h.current_version
      WHERE r.kind='mediaAsset' AND r.data->>'displayPolicy'='permitted_cache'
      ORDER BY v.fetched_at NULLS FIRST,r.id
      LIMIT $1`,
      [limit],
    )
  ).rows;
  const origins = (
    await db.query("SELECT id,origin,policy FROM source_origins")
  ).rows;
  const originByURL = new Map(origins.map((row) => [String(row.origin), row]));
  const dueBefore = now.getTime() - refreshSeconds * 1000;
  const bucket = Math.floor(now.getTime() / (refreshSeconds * 1000));
  let scheduled = 0;
  for (const row of rows) {
    const asset = json(row.data);
    if (
      !asset ||
      asset.displayPolicy !== "permitted_cache" ||
      typeof asset.originalURL !== "string"
    )
      continue;
    if (row.fetched_at && new Date(row.fetched_at).getTime() > dueBefore)
      continue;
    let origin: string;
    try {
      origin = new URL(asset.originalURL).origin;
    } catch {
      continue;
    }
    const originRow = originByURL.get(origin);
    const policy = originRow ? json(originRow.policy) : undefined;
    if (!isExplicitlyApprovedMediaPolicy(policy)) continue;
    if (
      await enqueue(
        db,
        JOB_KIND,
        { assetID: String(row.id) },
        `media:${row.id}:${bucket}`,
        now,
      )
    )
      scheduled += 1;
  }
  return scheduled;
}

/** Runs one fenced media job. New bytes create a review; they do not modify the published asset. */
export async function runMediaJob(
  db: DB,
  options: RunMediaJobOptions,
): Promise<boolean> {
  const job = await claim(db, JOB_KIND, LEASE_SECONDS);
  if (!job) return false;
  let reservation: { originID: string; policy: SourcePolicy } | undefined;
  try {
    const assetID =
      typeof job.payload?.assetID === "string" ? job.payload.assetID : "";
    const published = assetID
      ? await loadPublishedMedia(db, assetID)
      : undefined;
    if (!published || published.asset.displayPolicy !== "permitted_cache") {
      await complete(db, job.id, job.fencing_token);
      return true;
    }
    let originURL: string;
    try {
      originURL = new URL(published.asset.originalURL).origin;
    } catch {
      await complete(db, job.id, job.fencing_token);
      return true;
    }
    const origin = (
      await db.query("SELECT * FROM source_origins WHERE origin=$1", [
        originURL,
      ])
    ).rows[0];
    if (!origin || !isExplicitlyApprovedMediaPolicy(json(origin.policy))) {
      await complete(db, job.id, job.fencing_token);
      return true;
    }
    reservation = await reserveOrigin(db, String(origin.id), job.fencing_token);
    if (!reservation) {
      await db.query(
        "UPDATE jobs SET status='queued',attempts=attempts-1,run_at=now()+interval '5 minutes',lease_until=null WHERE id=$1 AND fencing_token=$2 AND status='running'",
        [job.id, job.fencing_token],
      );
      return true;
    }

    const result = await cacheMedia({
      asset: published.asset,
      sourcePolicy: reservation.policy,
      blobs: options.blobs,
      versions: new PostgresMediaVersionRepository(db),
      ...(options.fetch ? { fetch: options.fetch } : {}),
    });
    await finishMediaJob(db, job, reservation.originID, published, result);
  } catch (error) {
    if (reservation)
      await releaseOrigin(db, reservation.originID, job.fencing_token, 0);
    await fail(
      db,
      job.id,
      job.fencing_token,
      error instanceof Error ? error.message : String(error),
      boundedBackoff(job.attempts),
    );
  }
  return true;
}

async function finishMediaJob(
  db: DB,
  job: { id: string; fencing_token: string; attempts: number },
  originID: string,
  expected: PublishedMediaRow,
  result: CacheMediaResult,
): Promise<void> {
  await db.transaction(async (tx) => {
    const fenced = (
      await tx.query(
        "SELECT id FROM jobs WHERE id=$1 AND fencing_token=$2 AND status='running' AND lease_until>now() FOR UPDATE",
        [job.id, job.fencing_token],
      )
    ).rows[0];
    if (!fenced) throw new Error("lost media job lease");
    const byteSize =
      result.status === "cached" || result.status === "unchanged"
        ? result.fetchedByteSize
        : 0;
    await releaseOrigin(tx, originID, job.fencing_token, byteSize);

    if (result.status === "cached" || result.status === "unchanged") {
      const current = await loadPublishedMedia(tx, expected.asset.id);
      if (
        current &&
        current.eventID === expected.eventID &&
        current.revision === expected.revision &&
        current.asset.displayPolicy === "permitted_cache" &&
        current.asset.originalURL === expected.asset.originalURL
      ) {
        await createMediaReviewIfNeeded(tx, current, result.version);
      }
      await tx.query(
        "UPDATE source_origins SET last_success_at=now() WHERE id=$1",
        [originID],
      );
      if (!(await complete(tx, job.id, job.fencing_token)))
        throw new Error("lost media job lease");
      return;
    }

    if (
      result.status === "blocked" ||
      result.status === "missing" ||
      result.status === "not_fetched"
    ) {
      if (!(await complete(tx, job.id, job.fencing_token)))
        throw new Error("lost media job lease");
      return;
    }
    let delay = boundedBackoff(job.attempts);
    if (result.status === "rate_limited" && result.retryAfter) {
      delay = Math.max(delay, retryAfterSeconds(result.retryAfter));
      await tx.query(
        "UPDATE source_origins SET next_allowed_at=now()+($2*interval '1 second') WHERE id=$1",
        [originID, delay],
      );
    }
    if (!("issue" in result)) throw new Error("unexpected media result");
    await fail(tx, job.id, job.fencing_token, result.issue, delay);
  });
}

async function createMediaReviewIfNeeded(
  db: DB,
  current: PublishedMediaRow,
  version: Awaited<ReturnType<PostgresMediaVersionRepository["latest"]>> & {},
): Promise<void> {
  if (
    current.asset.contentHash === version.contentHash &&
    current.asset.version === version.version
  )
    return;
  const pending = (
    await db.query(
      "SELECT proposal FROM review_cases WHERE event_id=$1 AND base_revision=$2 AND status='pending'",
      [current.eventID, current.revision],
    )
  ).rows;
  if (
    pending.some((row) => {
      const proposal = json(row.proposal);
      const asset = proposal?.mediaAssets?.find(
        (candidate: any) => candidate.id === current.asset.id,
      );
      return (
        asset?.contentHash === version.contentHash &&
        asset?.version === version.version
      );
    })
  )
    return;
  const proposal = structuredClone(current.bundle);
  const index = proposal.mediaAssets.findIndex(
    (asset) => asset.id === current.asset.id,
  );
  if (index < 0) return;
  proposal.mediaAssets[index] = {
    ...proposal.mediaAssets[index]!,
    contentHash: version.contentHash,
    version: version.version,
  };
  proposal.evidence = proposal.evidence.map((evidence) =>
    evidence.recordID === current.asset.id &&
    (evidence.field === "kind" || evidence.field === "scope")
      ? { ...evidence, verification: "needsReview" as const }
      : evidence,
  );
  await createReview(db, proposal, current.revision, [
    {
      code: "media_content_changed",
      severity: "warning",
      assetID: current.asset.id,
      message:
        "Approved media URL returned different bytes. Re-verify its purpose, scope, image/PDF content, and significance before publishing this version.",
    },
  ]);
}

async function loadPublishedMedia(
  db: DB,
  assetID: string,
): Promise<PublishedMediaRow | undefined> {
  const row = (
    await db.query(
      "SELECT e.id AS event_id,e.revision,e.bundle,r.data FROM scoped_records r JOIN events e ON e.id=r.event_id WHERE r.id=$1 AND r.kind='mediaAsset' AND NOT e.deleted",
      [assetID],
    )
  ).rows[0];
  if (!row) return undefined;
  const bundle = json(row.bundle) as Bundle;
  const asset = bundle.mediaAssets.find(
    (candidate) => candidate.id === assetID,
  );
  if (!asset) return undefined;
  return {
    eventID: String(row.event_id),
    revision: Number(row.revision),
    bundle,
    asset,
  };
}

async function reserveOrigin(
  db: DB,
  originID: string,
  token: string,
): Promise<{ originID: string; policy: SourcePolicy } | undefined> {
  return db.transaction(async (tx) => {
    const row = (
      await tx.query("SELECT * FROM source_origins WHERE id=$1 FOR UPDATE", [
        originID,
      ])
    ).rows[0];
    if (!row) return undefined;
    const rawPolicy = json(row.policy);
    if (!isExplicitlyApprovedMediaPolicy(rawPolicy)) return undefined;
    const policy = structuredClone(rawPolicy) as SourcePolicy &
      Record<string, unknown>;
    const today = new Date().toISOString().slice(0, 10);
    const budgetDate = new Date(row.budget_date).toISOString().slice(0, 10);
    const requestCount = budgetDate === today ? Number(row.daily_requests) : 0;
    const byteCount = budgetDate === today ? Number(row.daily_bytes) : 0;
    policy.maxRedirects = Math.max(
      0,
      Math.min(5, Number(policy.maxRedirects ?? 5)),
    );
    policy.timeoutMs = Math.max(
      1,
      Math.min(20_000, Number(policy.timeoutMs ?? 20_000)),
    );
    const reservedRequests = policy.maxRedirects + 1;
    const requestBudget = Number(policy.requestBudget ?? 100);
    const byteBudget = Number(policy.byteBudget ?? 67_108_864);
    if (
      new Date(row.next_allowed_at).getTime() > Date.now() ||
      (row.fetch_lease_until &&
        new Date(row.fetch_lease_until).getTime() > Date.now()) ||
      requestCount + reservedRequests > requestBudget ||
      byteCount >= byteBudget
    )
      return undefined;
    policy.maxDecompressedBytes = Math.max(
      1,
      Math.min(
        Number(policy.maxDecompressedBytes ?? 25 * 1024 * 1024),
        byteBudget - byteCount,
      ),
    );
    await tx.query(
      `UPDATE source_origins
          SET daily_requests=$2,daily_bytes=$3,budget_date=CURRENT_DATE,
              next_allowed_at=now()+($4*interval '1 second'),last_attempt_at=now(),
              fetch_lease_until=now()+($5*interval '1 second'),fetch_lease_token=$6
        WHERE id=$1`,
      [
        originID,
        requestCount + reservedRequests,
        byteCount,
        Math.max(30, Number(policy.minimumIntervalSeconds ?? 60)),
        LEASE_SECONDS,
        token,
      ],
    );
    return { originID, policy };
  });
}

async function releaseOrigin(
  db: DB,
  originID: string,
  token: string,
  byteSize: number,
): Promise<void> {
  await db.query(
    "UPDATE source_origins SET fetch_lease_until=null,fetch_lease_token=null,daily_bytes=daily_bytes+$3 WHERE id=$1 AND fetch_lease_token=$2",
    [originID, token, byteSize],
  );
}

function isExplicitlyApprovedMediaPolicy(value: any): boolean {
  const contentTypes = Array.isArray(value?.contentTypes)
    ? value.contentTypes
    : [];
  return (
    value?.enabled === true &&
    value?.reviewStatus === "approved" &&
    typeof value?.robotsCheckedAt === "string" &&
    typeof value?.termsReviewedAt === "string" &&
    typeof value?.host === "string" &&
    Array.isArray(value?.allowedPaths) &&
    value.allowedPaths.length > 0 &&
    contentTypes.some((type: unknown) =>
      [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "application/pdf",
      ].includes(String(type)),
    )
  );
}

function boundedBackoff(attempt: number): number {
  return Math.min(6 * 60 * 60, 60 * 2 ** Math.max(0, attempt - 1));
}

function retryAfterSeconds(value: string): number {
  const numeric = Number(value);
  const seconds = Number.isFinite(numeric)
    ? numeric
    : (Date.parse(value) - Date.now()) / 1000;
  return Math.max(
    0,
    Math.min(24 * 60 * 60, Number.isFinite(seconds) ? Math.ceil(seconds) : 0),
  );
}

function json(value: any): any {
  return typeof value === "string" ? JSON.parse(value) : value;
}

export interface CandidateMediaJobInput {
  candidateID?: string;
  originalURL: string;
  displayPolicy: MediaDisplayPolicy;
  sourceURLs?: string[];
  section?: string;
  caption?: string;
  order?: number;
}

export interface RunCandidateMediaJobOptions {
  blobs: BlobStore;
  candidates: CandidateAssetStore;
  fetch?: (input: FetchDocumentInput) => Promise<FetchOutcome>;
}

/**
 * Queues a candidate download without touching published media.fetch jobs.
 * The display policy is stored as given; link_only is not rewritten to permitted_cache.
 */
export async function enqueueCandidateMedia(
  db: DB,
  input: CandidateMediaJobInput,
  now = new Date(),
): Promise<boolean> {
  if (!isDisplayPolicy(input.displayPolicy)) return false;
  let candidateID = input.candidateID;
  try {
    const url = new URL(input.originalURL);
    if (url.protocol !== "https:" && url.protocol !== "http:") return false;
    candidateID ||= candidateIDForURL(url.href);
  } catch {
    return false;
  }
  const bucket = Math.floor(now.getTime() / (MINIMUM_REFRESH_SECONDS * 1000));
  const id = await enqueue(
    db,
    CANDIDATE_JOB_KIND,
    {
      candidateID,
      originalURL: input.originalURL,
      displayPolicy: input.displayPolicy,
      ...(input.sourceURLs ? { sourceURLs: input.sourceURLs } : {}),
      ...(input.section ? { section: input.section } : {}),
      ...(input.caption ? { caption: input.caption } : {}),
      ...(input.order === undefined ? {} : { order: input.order }),
    },
    `candidate.media:${candidateID}:${bucket}`,
    now,
  );
  return Boolean(id);
}

/** Enqueues every discovered image. Does not drop images after the first or after eight. */
export async function enqueueDiscoveredCandidateMedia(
  db: DB,
  input: {
    html: string;
    pageURL: string;
    displayPolicy: MediaDisplayPolicy;
    now?: Date;
  },
): Promise<number> {
  if (!isDisplayPolicy(input.displayPolicy)) return 0;
  const images = discoverCandidateImages(input.html, input.pageURL);
  let queued = 0;
  for (const image of images) {
    if (
      await enqueueCandidateMedia(
        db,
        {
          candidateID: candidateIDForURL(image.url),
          originalURL: image.url,
          displayPolicy: input.displayPolicy,
          sourceURLs: [image.url],
          section: image.section,
          caption: image.caption,
          order: image.order,
        },
        input.now,
      )
    )
      queued += 1;
  }
  return queued;
}

/**
 * Runs one candidate.media.fetch job.
 * Ready bytes stay in the candidate index. This path does not create a review or publish.
 */
export async function runCandidateMediaJob(
  db: DB,
  options: RunCandidateMediaJobOptions,
): Promise<boolean> {
  const job = await claim(db, CANDIDATE_JOB_KIND, LEASE_SECONDS);
  if (!job) return false;
  const payload = job.payload ?? {};
  const originalURL =
    typeof payload.originalURL === "string" ? payload.originalURL : "";
  const displayPolicy = isDisplayPolicy(payload.displayPolicy)
    ? payload.displayPolicy
    : undefined;
  const candidateID =
    typeof payload.candidateID === "string" && payload.candidateID
      ? payload.candidateID
      : originalURL
        ? candidateIDForURL(originalURL)
        : "";
  if (!originalURL || !displayPolicy || !candidateID) {
    await complete(db, job.id, job.fencing_token);
    return true;
  }
  const stored = await options.candidates.get(candidateID);
  const effectivePolicy =
    displayPolicy === "link_only" || stored?.displayPolicy === "link_only"
      ? "link_only"
      : displayPolicy;
  if (effectivePolicy !== "permitted_cache") {
    try {
      await fetchCandidateMedia({
        candidateID,
        originalURL,
        displayPolicy: effectivePolicy,
        sourcePolicy: unusedPolicy(),
        blobs: options.blobs,
        candidates: options.candidates,
        sourceURLs: stringList(payload.sourceURLs),
        ...(typeof payload.section === "string"
          ? { section: payload.section }
          : {}),
        ...(typeof payload.caption === "string"
          ? { caption: payload.caption }
          : {}),
        ...(Number.isInteger(payload.order) ? { order: payload.order } : {}),
      });
      await complete(db, job.id, job.fencing_token);
    } catch (error) {
      await fail(
        db,
        job.id,
        job.fencing_token,
        error instanceof Error ? error.message : String(error),
        boundedBackoff(job.attempts),
      );
    }
    return true;
  }

  let reservation: { originID: string; policy: SourcePolicy } | undefined;
  try {
    let originURL: string;
    try {
      originURL = new URL(originalURL).origin;
    } catch {
      await complete(db, job.id, job.fencing_token);
      return true;
    }
    const origin = (
      await db.query("SELECT * FROM source_origins WHERE origin=$1", [
        originURL,
      ])
    ).rows[0];
    if (!origin || !isExplicitlyApprovedMediaPolicy(json(origin.policy))) {
      await complete(db, job.id, job.fencing_token);
      return true;
    }
    reservation = await reserveOrigin(db, String(origin.id), job.fencing_token);
    if (!reservation) {
      await db.query(
        "UPDATE jobs SET status='queued',attempts=attempts-1,run_at=now()+interval '5 minutes',lease_until=null WHERE id=$1 AND fencing_token=$2 AND status='running'",
        [job.id, job.fencing_token],
      );
      return true;
    }
    const result = await fetchCandidateMedia({
      candidateID,
      originalURL,
      displayPolicy,
      sourcePolicy: reservation.policy,
      blobs: options.blobs,
      candidates: options.candidates,
      sourceURLs: stringList(payload.sourceURLs),
      ...(typeof payload.section === "string"
        ? { section: payload.section }
        : {}),
      ...(typeof payload.caption === "string"
        ? { caption: payload.caption }
        : {}),
      ...(Number.isInteger(payload.order) ? { order: payload.order } : {}),
      ...(options.fetch ? { fetch: options.fetch } : {}),
    });
    await finishCandidateJob(db, job, reservation.originID, result);
  } catch (error) {
    if (reservation)
      await releaseOrigin(db, reservation.originID, job.fencing_token, 0);
    await fail(
      db,
      job.id,
      job.fencing_token,
      error instanceof Error ? error.message : String(error),
      boundedBackoff(job.attempts),
    );
  }
  return true;
}

async function finishCandidateJob(
  db: DB,
  job: { id: string; fencing_token: string; attempts: number },
  originID: string,
  result: FetchCandidateResult,
): Promise<void> {
  await db.transaction(async (tx) => {
    const fenced = (
      await tx.query(
        "SELECT id FROM jobs WHERE id=$1 AND fencing_token=$2 AND status='running' AND lease_until>now() FOR UPDATE",
        [job.id, job.fencing_token],
      )
    ).rows[0];
    if (!fenced) throw new Error("lost media job lease");
    const byteSize =
      result.status === "ready" && result.createdNewBytes
        ? (result.record.current?.byteSize ?? 0)
        : 0;
    await releaseOrigin(tx, originID, job.fencing_token, byteSize);
    if (result.status === "ready" || result.status === "unchanged") {
      await tx.query(
        "UPDATE source_origins SET last_success_at=now() WHERE id=$1",
        [originID],
      );
      if (!(await complete(tx, job.id, job.fencing_token)))
        throw new Error("lost media job lease");
      return;
    }
    if (
      result.status === "blocked" ||
      result.status === "missing" ||
      result.status === "not_fetched"
    ) {
      if (!(await complete(tx, job.id, job.fencing_token)))
        throw new Error("lost media job lease");
      return;
    }
    let delay = boundedBackoff(job.attempts);
    if (result.status === "rate_limited" && result.retryAfter) {
      delay = Math.max(delay, retryAfterSeconds(result.retryAfter));
      await tx.query(
        "UPDATE source_origins SET next_allowed_at=now()+($2*interval '1 second') WHERE id=$1",
        [originID, delay],
      );
    }
    if (!("issue" in result)) throw new Error("unexpected media result");
    await fail(tx, job.id, job.fencing_token, result.issue, delay);
  });
}

function isDisplayPolicy(value: unknown): value is MediaDisplayPolicy {
  return (
    value === "link_only" ||
    value === "permitted_remote_display" ||
    value === "permitted_cache"
  );
}

function stringList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const urls = value.filter((item) => typeof item === "string");
  return urls.length > 0 ? urls : undefined;
}

function unusedPolicy(): SourcePolicy {
  return {
    id: "not-fetched",
    enabled: false,
    reviewStatus: "pending_review",
    host: "invalid",
    allowedPaths: [],
  };
}
