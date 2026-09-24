import { randomUUID, createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { DB } from "./db.js";
import { DomainError, parseBundle } from "./contracts.js";
import { enqueue, claim, complete, fail } from "./queue.js";
import { blobStoreFromEnv, storeSnapshotBlob } from "./storage/index.js";
import { officialInstant } from "./local-time.js";
import { mergeSnapshotDetails } from "./proposal-details.js";
import { createReview } from "./publisher.js";
import { fetchDocument, type FetchDocumentInput } from "./ingestion/fetcher.js";
import { makeSnapshot } from "./ingestion/snapshot.js";
import { parseSnapshot, adapters } from "./ingestion/parser.js";
import { buildSectionGraph } from "./ingestion/section-graph.js";
import {
  bundlesInServerScanWindow,
  refreshIntervalSeconds,
} from "./refresh-policy.js";
import { slotStart } from "./update-window.js";
import type { FetchOutcome } from "./ingestion/types.js";
export const parserConfigurationVersion = createHash("sha256")
  .update(
    adapters
      .map((a) => `${a.id}:${a.version}`)
      .sort()
      .join("|"),
  )
  .digest("hex")
  .slice(0, 16);
import type {
  SourceSnapshot,
  FactCandidate,
  ParseResult,
} from "./ingestion/types.js";

export async function stableIdentity(db: DB, sourceKey: string, kind: string) {
  const id = randomUUID();
  await db.query(
    "INSERT INTO entity_aliases(source_key,entity_id,kind) VALUES($1,$2,$3) ON CONFLICT(source_key) DO NOTHING",
    [`${kind}:${sourceKey}`, id, kind],
  );
  return (
    await db.query("SELECT entity_id FROM entity_aliases WHERE source_key=$1", [
      `${kind}:${sourceKey}`,
    ])
  ).rows[0].entity_id as string;
}
export async function registerDocument(
  db: DB,
  url: string,
  policy?: Record<string, unknown>,
) {
  const parsed = new URL(url);
  if (parsed.protocol !== "https:")
    throw new DomainError(422, "HTTPS required");
  parsed.hash = "";
  const originID = randomUUID();
  const p = {
    id: parsed.hostname,
    host: parsed.hostname,
    enabled: false,
    reviewStatus: "pending_review",
    allowedPaths: [parsed.pathname],
    minimumIntervalSeconds: 60,
    requestBudget: 100,
    ...policy,
  };
  await db.query(
    "INSERT INTO source_origins(id,origin,policy) VALUES($1,$2,$3) ON CONFLICT(origin) DO NOTHING",
    [originID, parsed.origin, JSON.stringify(p)],
  );
  const origin = (
    await db.query("SELECT id FROM source_origins WHERE origin=$1", [
      parsed.origin,
    ])
  ).rows[0];
  await db.query(
    "INSERT INTO source_documents(id,origin_id,fetch_url,identity_url) VALUES($1,$2,$3,$3) ON CONFLICT(identity_url) DO NOTHING",
    [randomUUID(), origin.id, parsed.href],
  );
  return (
    await db.query("SELECT * FROM source_documents WHERE identity_url=$1", [
      parsed.href,
    ])
  ).rows[0];
}
export async function scheduleSources(db: DB, now = new Date()) {
  return db.transaction(async (tx) => {
    const documents = (
      await tx.query(
        "SELECT d.*,o.policy FROM source_documents d JOIN source_origins o ON d.origin_id=o.id WHERE d.enabled AND o.policy->>'enabled'='true' AND o.policy->>'reviewStatus'='approved' AND d.next_fetch_at<=now() ORDER BY d.next_fetch_at FOR UPDATE OF d SKIP LOCKED LIMIT 100",
      )
    ).rows;
    let scheduled = 0;
    for (const d of documents) {
      const bundles = (
        await tx.query(
          "SELECT DISTINCT e.bundle FROM events e WHERE NOT e.deleted AND (e.bundle->'event'->>'primarySourceURL'=$1 OR EXISTS(SELECT 1 FROM jsonb_array_elements(e.bundle->'evidence') fact JOIN source_snapshots s ON s.id::text=fact->>'snapshotID' WHERE s.document_id=$2))",
          [d.fetch_url, d.id],
        )
      ).rows.map((r) => r.bundle);
      // Archived tours are not fetched on the periodic pass. Manual jobs are separate.
      if (!bundlesInServerScanWindow(bundles, now)) {
        await tx.query(
          "UPDATE source_documents SET next_fetch_at=now()+interval '1 day' WHERE id=$1",
          [d.id],
        );
        continue;
      }
      await enqueue(
        tx,
        "fetch",
        { documentID: d.id },
        `fetch:${d.id}:${new Date(d.next_fetch_at).toISOString()}`,
      );
      scheduled += 1;
      const timed = bundles.filter(
        (bundle: any) =>
          Array.isArray(bundle?.performances) &&
          Array.isArray(bundle?.ticketRounds) &&
          Array.isArray(bundle?.goodsCampaigns) &&
          Array.isArray(bundle?.streamOffers),
      );
      await tx.query(
        "UPDATE source_documents SET next_fetch_at=now()+($2*interval '1 second') WHERE id=$1",
        [
          d.id,
          refreshIntervalSeconds(timed, d.adapter_id, d.policy, now.getTime()),
        ],
      );
    }
    return scheduled;
  });
}

/** Plan version is part of the update-run unique key, together with the UTC slot. */
export const updatePlanVersion = "p1-2026-09-24";

/** UTC 00:00 or 12:00 slot containing `now`. Not a Japan-local or phone-local half day. */
export function currentUpdateSlot(now = new Date()): string {
  return slotStart(now).toISOString();
}

function asObject(value: unknown): Record<string, unknown> {
  if (typeof value === "string")
    return JSON.parse(value) as Record<string, unknown>;
  if (value && typeof value === "object")
    return value as Record<string, unknown>;
  return {};
}

/**
 * Persist one update run for the current UTC slot.
 * An unfinished run is resumed instead of inserting every slot missed while down.
 */
export async function scheduleUpdateSlot(db: DB, now = new Date()) {
  return db.transaction(async (tx) => {
    await tx.query("LOCK TABLE jobs IN SHARE ROW EXCLUSIVE MODE");
    const open = (
      await tx.query(
        "SELECT id, payload FROM jobs WHERE kind='update_run' AND payload->>'planVersion'=$1 AND status IN ('queued','running') ORDER BY payload->>'slot' DESC LIMIT 1",
        [updatePlanVersion],
      )
    ).rows[0];
    if (open) {
      const payload = asObject(open.payload);
      return {
        jobID: String(open.id),
        slot: String(payload.slot),
        resumed: true,
        created: false,
      };
    }
    const slot = currentUpdateSlot(now);
    const key = `update-run:${updatePlanVersion}:${slot}`;
    const existing = (
      await tx.query(
        "SELECT id, status FROM jobs WHERE dedupe_key=$1",
        [key],
      )
    ).rows[0];
    if (existing)
      return {
        jobID: String(existing.id),
        slot,
        resumed: existing.status === "queued" || existing.status === "running",
        created: false,
      };
    const id = await enqueue(
      tx,
      "update_run",
      { planVersion: updatePlanVersion, slot },
      key,
    );
    if (!id) throw new Error("update slot was not persisted");
    return { jobID: String(id), slot, resumed: false, created: true };
  });
}

export async function runUpdateSlotJob(db: DB) {
  const job = await claim(db, "update_run", 180);
  if (!job) return false;
  try {
    await scheduleSources(db);
    if (!(await complete(db, job.id, job.fencing_token))) return true;
  } catch (error) {
    await fail(db, job.id, job.fencing_token, String(error), 300);
  }
  return true;
}
export async function saveSnapshot(db: DB, snapshot: SourceSnapshot) {
  const store = blobStoreFromEnv();
  const blob = store ? await storeSnapshotBlob(store, snapshot) : undefined;
  const id = randomUUID();
  const metadata = {
    fetchUrl: snapshot.fetchUrl,
    finalUrl: snapshot.finalUrl,
    headers: snapshot.headers,
    statusCode: snapshot.statusCode,
    fetchedAt: snapshot.fetchedAt,
    normalizedSha256: snapshot.normalizedSha256,
    redirectChain: snapshot.redirectChain,
  };
  await db.query(
    "INSERT INTO source_snapshots(id,document_id,content_hash,body,metadata,observed_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(document_id,content_hash) DO NOTHING",
    [
      id,
      snapshot.sourceDocumentId,
      snapshot.rawSha256,
      snapshot.text,
      JSON.stringify(metadata),
      snapshot.fetchedAt,
    ],
  );
  const row = (
    await db.query(
      "SELECT id FROM source_snapshots WHERE document_id=$1 AND content_hash=$2",
      [snapshot.sourceDocumentId, snapshot.rawSha256],
    )
  ).rows[0];
  if (blob)
    await db.query(
      "UPDATE source_snapshots SET blob_key=$2,byte_size=$3 WHERE id=$1",
      [row.id, blob.key, blob.byteSize],
    );
  return { ...snapshot, id: row.id };
}
function hydrate(row: any, document: any): SourceSnapshot {
  const m = row.metadata;
  return {
    ...makeSnapshot({
      sourceDocumentId: document.id,
      fetchUrl: m.fetchUrl ?? document.fetch_url,
      finalUrl: m.finalUrl ?? document.fetch_url,
      headers: m.headers ?? {},
      statusCode: m.statusCode ?? 200,
      fetchedAt: new Date(row.observed_at).toISOString(),
      body: Buffer.from(row.body),
      redirectChain: m.redirectChain ?? [],
    }),
    id: row.id,
  };
}
export async function parseAndStore(db: DB, snapshot: SourceSnapshot) {
  const result = parseSnapshot(snapshot);
  for (const c of result.candidates)
    await db.query(
      "INSERT INTO fact_candidates(id,snapshot_id,source_key,kind,data,evidence,issues) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT DO NOTHING",
      [
        randomUUID(),
        snapshot.id,
        c.entityRef.sourceKey ?? snapshot.finalUrl,
        c.field,
        JSON.stringify(c.value),
        JSON.stringify(c),
        JSON.stringify(result.issues),
      ],
    );
  await db.query(
    "UPDATE source_documents SET adapter_id=$2,health=$3 WHERE id=$1",
    [
      snapshot.sourceDocumentId,
      result.adapterId ?? null,
      result.issues.some((i) => i.severity === "error")
        ? "parse_failed"
        : "healthy",
    ],
  );
  const graph = buildSectionGraph(snapshot, result);
  for (const block of graph.blocks)
    await db.query(
      "INSERT INTO fact_candidates(id,snapshot_id,source_key,kind,data,evidence,issues) VALUES($1,$2,$3,'dom.block',$4::jsonb,$5::jsonb,$6::jsonb) ON CONFLICT DO NOTHING",
      [
        randomUUID(),
        snapshot.id,
        block.blockID,
        JSON.stringify({
          ...block,
          identityTableVersion: graph.identityTableVersion,
        }),
        JSON.stringify({ evidence: { locator: block.domPath || block.blockID } }),
        "[]",
      ],
    );
  // Discovery adds review-only documents, never implicitly authorizes a new origin/path.
  for (const link of result.links.slice(0, 50))
    if (["event", "ticket", "goods", "news"].includes(link.role))
      await registerDocument(db, link.url);
  return result;
}
export async function runFetchJob(
  db: DB,
  fetcher: (
    input: FetchDocumentInput,
  ) => Promise<FetchOutcome> = fetchDocument,
) {
  const job = await claim(db, "fetch", 180);
  if (!job) return false;
  try {
    const d = (
      await db.query(
        "SELECT d.*,o.policy,o.id AS origin_key FROM source_documents d JOIN source_origins o ON o.id=d.origin_id WHERE d.id=$1",
        [job.payload.documentID],
      )
    ).rows[0];
    if (!d || !d.enabled) throw new DomainError(409, "Document is disabled");
    const policy = d.policy;
    if (
      !policy.enabled ||
      policy.reviewStatus !== "approved" ||
      !policy.robotsCheckedAt ||
      !policy.termsReviewedAt
    )
      throw new DomainError(409, "Source policy review incomplete");
    const allowed = await db.transaction(async (tx) => {
      const o = (
        await tx.query("SELECT * FROM source_origins WHERE id=$1 FOR UPDATE", [
          d.origin_key,
        ])
      ).rows[0];
      const budgetDate = new Date(o.budget_date).toISOString().slice(0, 10),
        today = new Date().toISOString().slice(0, 10);
      const count = budgetDate === today ? o.daily_requests : 0;
      const bytes = budgetDate === today ? Number(o.daily_bytes) : 0;
      const reservedRequests = Number(policy.maxRedirects ?? 5) + 1;
      if (
        new Date(o.next_allowed_at) > new Date() ||
        (o.fetch_lease_until && new Date(o.fetch_lease_until) > new Date()) ||
        count + reservedRequests > Number(policy.requestBudget ?? 100) ||
        bytes >= Number(policy.byteBudget ?? 67108864)
      )
        return false;
      policy.maxDecompressedBytes = Math.min(
        Number(policy.maxDecompressedBytes ?? 5242880),
        Number(policy.byteBudget ?? 67108864) - bytes,
      );
      await tx.query(
        "UPDATE source_origins SET daily_requests=$2,daily_bytes=$3,budget_date=CURRENT_DATE,next_allowed_at=now()+($4*interval '1 second'),last_attempt_at=now(),fetch_lease_until=now()+interval '180 seconds',fetch_lease_token=$5 WHERE id=$1",
        [
          d.origin_key,
          count + reservedRequests,
          bytes,
          Math.max(30, Number(policy.minimumIntervalSeconds ?? 60)),
          job.fencing_token,
        ],
      );
      return true;
    });
    if (!allowed) {
      await db.query(
        "UPDATE jobs SET status='queued',attempts=attempts-1,run_at=now()+interval '5 minutes',lease_until=null WHERE id=$1 AND fencing_token=$2",
        [job.id, job.fencing_token],
      );
      return true;
    }
    const old = d.last_snapshot_id
      ? (
          await db.query("SELECT * FROM source_snapshots WHERE id=$1", [
            d.last_snapshot_id,
          ])
        ).rows[0]
      : null;
    const outcome = await fetcher({
      url: d.fetch_url,
      sourceDocumentId: d.id,
      policy,
      previousSnapshot: old ? hydrate(old, d) : undefined,
    });
    await db.transaction(async (tx) => {
      const lease = (
        await tx.query(
          "SELECT id FROM jobs WHERE id=$1 AND fencing_token=$2 AND status='running' AND lease_until>now() FOR UPDATE",
          [job.id, job.fencing_token],
        )
      ).rows[0];
      if (!lease) throw new DomainError(409, "Lost worker lease");
      await tx.query(
        "UPDATE source_origins SET fetch_lease_until=null,fetch_lease_token=null,daily_bytes=daily_bytes+$3 WHERE id=$1 AND fetch_lease_token=$2",
        [
          d.origin_key,
          job.fencing_token,
          outcome.status === "snapshotted" ? outcome.snapshot.body.length : 0,
        ],
      );
      await tx.query(
        "INSERT INTO source_fetches(id,document_id,outcome,metadata) VALUES($1,$2,$3,$4)",
        [
          randomUUID(),
          d.id,
          outcome.status,
          JSON.stringify({
            statusCode:
              outcome.status === "unchanged"
                ? 304
                : "statusCode" in outcome
                  ? outcome.statusCode
                  : undefined,
            issue: "issue" in outcome ? outcome.issue : undefined,
            ...(outcome.status === "unchanged"
              ? { checkedAt: outcome.checkedAt, conditional: true }
              : {}),
          }),
        ],
      );
      // A conditional GET has no new body and must not insert another content snapshot.
      if (outcome.status === "unchanged") {
        await tx.query(
          "UPDATE source_documents SET health='healthy' WHERE id=$1",
          [d.id],
        );
        await tx.query(
          "UPDATE source_origins SET health='healthy',last_success_at=now() WHERE id=$1",
          [d.origin_key],
        );
        await complete(tx, job.id, job.fencing_token);
      } else if (outcome.status === "snapshotted") {
        const snapshot = await saveSnapshot(tx, outcome.snapshot);
        await tx.query(
          "UPDATE source_documents SET last_snapshot_id=$2,etag=$3,last_modified=$4,health='healthy' WHERE id=$1",
          [
            d.id,
            snapshot.id,
            snapshot.headers.etag ?? null,
            snapshot.headers["last-modified"] ?? null,
          ],
        );
        await tx.query(
          "UPDATE source_origins SET health='healthy',last_success_at=now(),last_content_change_at=CASE WHEN $2 THEN now() ELSE last_content_change_at END WHERE id=$1",
          [d.origin_key, snapshot.id !== d.last_snapshot_id],
        );
        await enqueue(
          tx,
          "parse",
          { snapshotID: snapshot.id },
          `parse:${snapshot.id}:${parserConfigurationVersion}`,
        );
        await complete(tx, job.id, job.fencing_token);
      } else {
        await tx.query(
          "UPDATE source_documents SET health=$2,enabled=CASE WHEN $2='blocked' THEN false ELSE enabled END WHERE id=$1",
          [d.id, outcome.status === "blocked" ? "blocked" : "fetch_failed"],
        );
        await tx.query("UPDATE source_origins SET health=$2 WHERE id=$1", [
          d.origin_key,
          outcome.status,
        ]);
        let delay = 60 * 2 ** job.attempts;
        if (outcome.status === "rate_limited" && outcome.retryAfter) {
          const n = Number(outcome.retryAfter);
          delay = Math.max(
            delay,
            Number.isFinite(n)
              ? n
              : (Date.parse(outcome.retryAfter) - Date.now()) / 1000,
          );
          await tx.query(
            "UPDATE source_origins SET next_allowed_at=now()+($2*interval '1 second') WHERE id=$1",
            [d.origin_key, Math.max(0, delay)],
          );
        }
        if (outcome.status === "blocked" || outcome.status === "missing")
          await complete(tx, job.id, job.fencing_token);
        else
          await fail(
            tx,
            job.id,
            job.fencing_token,
            outcome.issue,
            Math.max(60, delay),
          );
      }
    });
  } catch (error) {
    await db.query(
      "UPDATE source_origins SET fetch_lease_until=null,fetch_lease_token=null WHERE fetch_lease_token=$1",
      [job.fencing_token],
    );
    await fail(db, job.id, job.fencing_token, String(error), 300);
  }
  return true;
}
export async function runParseJob(db: DB) {
  const job = await claim(db, "parse", 120);
  if (!job) return false;
  try {
    await db.transaction(async (tx) => {
      const row = (
        await tx.query(
          "SELECT s.*,d.fetch_url FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE s.id=$1",
          [job.payload.snapshotID],
        )
      ).rows[0];
      if (!row) throw new Error("Snapshot not found");
      const snapshot = hydrate(row, {
        id: row.document_id,
        fetch_url: row.fetch_url,
      });
      const result = await parseAndStore(tx, snapshot);
      const linked = (
        await tx.query(
          "SELECT DISTINCT e.bundle,e.revision FROM events e JOIN LATERAL jsonb_array_elements(e.bundle->'evidence') fact ON true JOIN source_snapshots prior ON prior.id::text=fact->>'snapshotID' WHERE NOT e.deleted AND prior.document_id=$1",
          [snapshot.sourceDocumentId],
        )
      ).rows;
      if (linked.length) {
        for (const event of linked) {
          if (
            event.bundle.event.primarySourceURL === snapshot.fetchUrl &&
            result.candidates.some((c) => c.field === "performance.schedule")
          )
            await proposeSnapshot(tx, snapshot.id);
          else {
            const draft = await mergeSnapshotDetails(
              tx,
              parseBundle(event.bundle),
              result,
              snapshot,
            );
            await createReview(tx, draft, event.revision, [
              ...result.issues,
              {
                message:
                  "Linked source changed; verify affected scope, removed sections and schedule before publication.",
              },
            ]);
          }
        }
      } else if (
        result.candidates.some((c) => c.field === "performance.schedule")
      )
        await proposeSnapshot(tx, snapshot.id);
      if (!(await complete(tx, job.id, job.fencing_token)))
        throw new Error("Lost parse lease");
    });
  } catch (e) {
    await fail(db, job.id, job.fencing_token, String(e));
  }
  return true;
}
export async function importSnapshot(db: DB, url: string, path: string) {
  const doc = await registerDocument(db, url);
  const snapshot = await saveSnapshot(
    db,
    makeSnapshot({
      sourceDocumentId: doc.id,
      fetchUrl: url,
      finalUrl: url,
      statusCode: 200,
      headers: { "content-type": "text/html; charset=utf-8" },
      body: await readFile(path),
    }),
  );
  const result = await parseAndStore(db, snapshot);
  return { snapshot, result };
}

/** Assembles extracted candidates only. It never certifies or publishes them. */
export async function proposeSnapshot(db: DB, snapshotID: string) {
  const row = (
    await db.query(
      "SELECT s.*,d.fetch_url FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE s.id=$1",
      [snapshotID],
    )
  ).rows[0];
  if (!row) throw new DomainError(404, "Snapshot not found");
  const snapshot = hydrate(row, {
    id: row.document_id,
    fetch_url: row.fetch_url,
  });
  const parsed = parseSnapshot(snapshot);
  const title = parsed.candidates.find(
    (c) => c.field === "event.officialTitle",
  );
  const schedules = parsed.candidates.filter(
    (c) => c.field === "performance.schedule",
  );
  if (!title || !schedules.length)
    throw new DomainError(
      422,
      "No verified template with structured performance schedules; manual evidence-based proposal required",
    );
  const eventID = await stableIdentity(db, snapshot.fetchUrl, "event");
  const existing = (
    await db.query("SELECT bundle,revision FROM events WHERE id=$1", [eventID])
  ).rows[0];
  const now = new Date().toISOString();
  const evidence: any[] = [];
  const ev = (
    recordID: string,
    field: string,
    c: FactCandidate,
    performanceIDs: string[] = [],
  ) =>
    evidence.push({
      id: randomUUID(),
      recordID,
      field,
      sourceURL: snapshot.finalUrl,
      quote: c.evidence.rawText,
      snapshotID,
      locator: c.evidence.locator,
      sourcePublishedAt: null,
      observedAt: snapshot.fetchedAt,
      verifiedAt: now,
      verification: "needsReview",
      adapterVersion: c.parserVersion,
      performanceIDs,
    });
  ev(eventID, "officialTitle", title);
  const venues = parsed.candidates.filter(
    (c) => c.field === "performance.venueRaw",
  );
  const performances: import("./contracts.js").Bundle["performances"] = [];
  const seenLabels = new Set<string>();
  for (const c of schedules) {
    const venue =
      venues.find(
        (candidate) => candidate.entityRef.sourceKey === c.entityRef.sourceKey,
      ) ??
      (venues.length === 1 &&
      !venues[0]!.entityRef.sourceKey?.includes("#performance:")
        ? venues[0]
        : undefined);
    const v = c.value as any;
    const label = v.dayLabel;
    if (!label || seenLabels.has(label))
      throw new DomainError(
        422,
        "Ambiguous performance identity: review explicit session labels before mapping",
      );
    seenLabels.add(label);
    const id = await stableIdentity(
      db,
      `${snapshot.fetchUrl}#session:${label}`,
      "performance",
    );
    const iso = (clock: string | null | undefined) =>
      officialInstant(v.localDate, clock, v.timeZone ?? "Asia/Tokyo");
    const cast = parsed.candidates.find(
      (f) =>
        f.field === "performance.performers" &&
        (f.entityRef.sourceKey === c.entityRef.sourceKey ||
          schedules.length === 1),
    );
    const p = {
      id,
      eventID,
      stopID: null,
      subtitle: null,
      dayLabel: label,
      localDate: v.localDate,
      precision: (v.doorsAt || v.startsAt ? "minute" : "date") as
        | "minute"
        | "date",
      rawDate: v.raw ?? null,
      doorsAt: iso(v.doorsAt),
      startAt: iso(v.startsAt),
      venueName: venue ? String(venue.value) : "",
      venueCity: "",
      performers:
        cast && Array.isArray(cast.value) ? (cast.value as string[]) : [],
      order: performances.length,
    };
    performances.push(p);
    if (cast) ev(id, "performers", cast, [id]);
    ev(id, "localDate", c, [id]);
    if (p.doorsAt) ev(id, "doorsAt", c, [id]);
    if (p.startAt) ev(id, "startAt", c, [id]);
    if (venue) ev(id, "venueName", venue, [id]);
  }
  const eventTypes = ["live", "fanMeeting", "screening", "other"] as const;
  const eventStatuses = [
    "scheduled",
    "postponed",
    "cancelled",
    "finished",
  ] as const;
  const statedEventType = parsed.candidates.find(
    (c) => c.field === "event.eventType",
  )?.value;
  const statedStatus = parsed.candidates.find(
    (c) => c.field === "event.status",
  )?.value;
  // Same event id may already exist. Field values are this snapshot only.
  const bundle = parseBundle({
    schemaVersion: 1,
    publishedAt: now,
    event: {
      id: eventID,
      franchise:
        new URL(snapshot.finalUrl).hostname === "bang-dream.com"
          ? "bangdream"
          : "lovelive",
      officialTitle: title.value,
      groups: [...new Set(performances.flatMap((p) => p.performers))],
      eventType: eventTypes.find((kind) => kind === statedEventType) ?? "live",
      status:
        eventStatuses.find((kind) => kind === statedStatus) ?? "scheduled",
      primarySourceURL: snapshot.finalUrl,
      timeZone: "Asia/Tokyo",
    },
    performances,
    editions: [],
    stops: [],
    ticketTiers: [],
    ticketRounds: [],
    ticketBenefits: [],
    ticketOffers: [],
    streamOffers: [],
    goodsCampaigns: [],
    products: [],
    goodsSessions: [],
    mediaAssets: [],
    notices: [],
    evidence,
  });
  const detailed = await mergeSnapshotDetails(db, bundle, parsed, snapshot);
  const review = await createReview(db, detailed, existing?.revision ?? 0, [
    ...parsed.issues,
    {
      message:
        "First template identity, cast, venue applicability and missing fields require review; no ticket/media inference.",
    },
  ]);
  return { ...review, performanceCount: performances.length };
}

export async function augmentReviewFromSnapshot(
  db: DB,
  reviewID: string,
  snapshotID: string,
  performanceID?: string,
) {
  return db.transaction(async (tx) => {
    const review = (
      await tx.query(
        "SELECT * FROM review_cases WHERE id=$1 AND status='pending' FOR UPDATE",
        [reviewID],
      )
    ).rows[0];
    if (!review) throw new DomainError(409, "Pending review not found");
    const row = (
      await tx.query(
        "SELECT s.*,d.fetch_url FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE s.id=$1",
        [snapshotID],
      )
    ).rows[0];
    if (!row) throw new DomainError(404, "Snapshot not found");
    const snapshot = hydrate(row, {
      id: row.document_id,
      fetch_url: row.fetch_url,
    });
    const bundle = await mergeSnapshotDetails(
      tx,
      parseBundle(review.proposal),
      parseSnapshot(snapshot),
      snapshot,
      performanceID,
    );
    await tx.query("UPDATE review_cases SET proposal=$2 WHERE id=$1", [
      reviewID,
      JSON.stringify(bundle),
    ]);
    return {
      id: reviewID,
      ticketRounds: bundle.ticketRounds.length,
      goodsCampaigns: bundle.goodsCampaigns.length,
      mediaAssets: bundle.mediaAssets.length,
    };
  });
}
