import { load } from "cheerio";
import { createHash, randomUUID } from "node:crypto";
import {
  acceptEventRevision,
  assertEvidence,
  parseBundle,
  DomainError,
  mergeProposedField,
  type Bundle,
} from "./contracts.js";
import type { DB } from "./db.js";
import {
  createValidationReceipt,
  type ValidationReceipt,
} from "./validation-receipt.js";
export function canonical(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object")
    return `{${Object.entries(value)
      .filter(([, v]) => v !== undefined)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([k, v]) => `${JSON.stringify(k)}:${canonical(v)}`)
      .join(",")}}`;
  return JSON.stringify(value);
}
export function businessHash(bundle: Bundle) {
  const copy = structuredClone(bundle);
  delete (copy as any).publishedAt;
  delete (copy as any).revision;
  delete (copy as any).sourceHealth;
  copy.evidence = [];
  return createHash("sha256").update(canonical(copy)).digest("hex");
}
export async function createReview(
  db: DB,
  input: unknown,
  baseRevision: number,
  issues: unknown[] = [],
) {
  const bundle = parseBundle(input);
  const id = randomUUID();
  await db.query(
    "INSERT INTO review_cases(id,event_id,base_revision,proposal,issues) VALUES($1,$2,$3,$4,$5)",
    [
      id,
      bundle.event.id,
      baseRevision,
      JSON.stringify(bundle),
      JSON.stringify(issues),
    ],
  );
  return { id, eventID: bundle.event.id, status: "pending" };
}

function keepNulls<T extends { id: string }>(
  verified: T | undefined,
  proposed: T,
  fields: string[],
) {
  if (!verified) return false;
  const next = proposed as Record<string, unknown>;
  const previous = verified as Record<string, unknown>;
  let kept = false;
  for (const field of fields) {
    if (next[field] !== null) continue;
    const merged = mergeProposedField(
      (previous[field] ?? null) as null,
      null,
      // A proposed null is not an explicit verified retraction.
      { verified: false },
    );
    if (merged !== null) {
      next[field] = merged;
      kept = true;
    }
  }
  return kept;
}

function alignByID<T extends { id: string }>(
  verified: T[] | undefined,
  proposed: T[],
  fields: string[],
) {
  let kept = false;
  for (const record of proposed) {
    if (
      keepNulls(
        verified?.find((item) => item.id === record.id),
        record,
        fields,
      )
    )
      kept = true;
  }
  return kept;
}

/**
 * A proposed null is not a verified retraction, including after fetch_failed,
 * blocked, or parse_failed. mergeProposedField keeps the confirmed value.
 */
export function retainConfirmedFields(verified: Bundle, proposed: Bundle) {
  if (!verified) return proposed;
  const next = structuredClone(proposed);
  let kept = false;
  if (
    alignByID(verified.performances, next.performances, [
      "localDate",
      "doorsAt",
      "startAt",
    ])
  )
    kept = true;
  if (alignByID(verified.ticketTiers, next.ticketTiers, ["priceJPY", "amount"]))
    kept = true;
  if (
    alignByID(verified.ticketRounds, next.ticketRounds, [
      "applyStartAt",
      "applyEndAt",
      "resultAt",
      "paymentDeadlineAt",
      "eligibility",
      "paymentStartAt",
    ])
  )
    kept = true;
  if (
    alignByID(verified.ticketOffers, next.ticketOffers, ["priceJPY", "amount"])
  )
    kept = true;
  if (
    alignByID(verified.streamOffers, next.streamOffers, [
      "salesStartAt",
      "salesEndAt",
      "archiveAvailableUntil",
      "regionNote",
      "amount",
    ])
  )
    kept = true;
  if (
    alignByID(verified.goodsCampaigns, next.goodsCampaigns, [
      "salesStartAt",
      "salesEndAt",
      "requiresTicket",
      "purchaseLimit",
    ])
  )
    kept = true;
  if (alignByID(verified.products, next.products, ["amount"])) kept = true;
  for (const product of next.products) {
    const previous = verified.products.find((item) => item.id === product.id);
    if (alignByID(previous?.variants, product.variants, ["amount"]))
      kept = true;
  }
  if (
    alignByID(verified.goodsSessions, next.goodsSessions, [
      "startsAt",
      "endsAt",
    ])
  )
    kept = true;
  return kept ? next : proposed;
}

export type AutoPublishIssue = { code: string; message: string };

function scopedRecords(bundle: Bundle) {
  return [
    ...bundle.ticketRounds,
    ...bundle.ticketBenefits,
    ...bundle.streamOffers,
    ...bundle.goodsCampaigns,
    ...bundle.goodsSessions,
    ...bundle.mediaAssets,
    ...bundle.notices,
  ];
}

function downloadable(policy: string) {
  return policy === "permitted_cache" || policy === "permitted_remote_display";
}

export function newlyReferencedDownloadableAssets(
  previous: Bundle | null,
  bundle: Bundle,
) {
  const prior = new Map(
    (previous?.mediaAssets ?? []).map((asset) => [asset.id, asset]),
  );
  return bundle.mediaAssets
    .filter((asset) => {
      if (!downloadable(asset.displayPolicy)) return false;
      const old = prior.get(asset.id);
      return !old || !downloadable(old.displayPolicy);
    })
    .map((asset) => asset.id);
}

/**
 * Whole-bundle gate. Conflicts stay in review; confirmed fields are not removed
 * to make the remainder pass. Scope is left as performances or unconfirmed.
 */
export function autoPublishIssues(
  bundle: Bundle,
  receipt: ValidationReceipt,
  previous: Bundle | null,
): AutoPublishIssue[] {
  const issues: AutoPublishIssue[] = [];
  for (const record of scopedRecords(bundle)) {
    if (record.scope.kind === "unconfirmed")
      issues.push({
        code: "unconfirmed_scope",
        message: `${record.id} scope is unconfirmed`,
      });
  }
  for (const check of receipt.scopeChecks) {
    if (check.kind === "unconfirmed" || check.outcome === "needsReview")
      issues.push({
        code: "unconfirmed_scope",
        message: `${check.recordID} scope check needs review`,
      });
  }
  for (const evidence of bundle.evidence) {
    if (evidence.verification === "conflict")
      issues.push({
        code: "conflicting_evidence",
        message: `${evidence.recordID}.${evidence.field}`,
      });
  }
  for (const check of receipt.fieldChecks) {
    if (check.outcome !== "pass")
      issues.push({
        code:
          check.outcome === "conflict"
            ? "conflicting_evidence"
            : "field_needs_review",
        message: `${check.recordID}.${check.field}`,
      });
  }
  try {
    assertEvidence(bundle);
  } catch (error) {
    if (!(error instanceof DomainError)) throw error;
    issues.push({ code: "missing_evidence", message: error.message });
  }
  const ready = new Set(receipt.readyAssetIDs);
  for (const assetID of newlyReferencedDownloadableAssets(previous, bundle)) {
    if (!ready.has(assetID))
      issues.push({
        code: "asset_not_ready",
        message: `${assetID} is not in the validation receipt ready list`,
      });
  }
  return issues;
}

async function normalize(tx: DB, b: Bundle) {
  const eventID = b.event.id;
  await tx.query("DELETE FROM ticket_offers WHERE event_id=$1", [eventID]);
  await tx.query("DELETE FROM scoped_records WHERE event_id=$1", [eventID]);
  await tx.query("DELETE FROM performances WHERE event_id=$1", [eventID]);
  await tx.query("DELETE FROM stops WHERE event_id=$1", [eventID]);
  await tx.query("DELETE FROM editions WHERE event_id=$1", [eventID]);
  for (const e of b.editions)
    await tx.query("INSERT INTO editions(id,event_id,data) VALUES($1,$2,$3)", [
      e.id,
      eventID,
      JSON.stringify(e),
    ]);
  for (const s of b.stops)
    await tx.query(
      "INSERT INTO stops(id,event_id,edition_id,data) VALUES($1,$2,$3,$4)",
      [s.id, eventID, s.editionID ?? null, JSON.stringify(s)],
    );
  for (const p of b.performances)
    await tx.query(
      "INSERT INTO performances(id,event_id,stop_id,edition_id,local_date,data) VALUES($1,$2,$3,$4,$5,$6)",
      [
        p.id,
        eventID,
        p.stopID,
        p.editionID ?? null,
        p.localDate,
        JSON.stringify(p),
      ],
    );
  for (const [kind, records] of Object.entries({
    ticketTier: b.ticketTiers,
    ticketRound: b.ticketRounds,
    streamOffer: b.streamOffers,
    goodsCampaign: b.goodsCampaigns,
    product: b.products,
    goodsSession: b.goodsSessions,
    mediaAsset: b.mediaAssets,
    notice: b.notices,
  }))
    for (const r of records) {
      await tx.query(
        "INSERT INTO scoped_records(id,event_id,kind,data) VALUES($1,$2,$3,$4)",
        [r.id, eventID, kind, JSON.stringify(r)],
      );
      if ("scope" in r && r.scope.kind === "performances")
        for (const p of r.scope.performanceIDs)
          await tx.query(
            "INSERT INTO applicability_members(record_id,performance_id) VALUES($1,$2)",
            [r.id, p],
          );
    }
  for (const o of b.ticketOffers)
    await tx.query(
      "INSERT INTO ticket_offers(id,event_id,round_id,tier_id,data) VALUES($1,$2,$3,$4,$5)",
      [o.id, eventID, o.roundID, o.tierID, JSON.stringify(o)],
    );
}

type StoredEvent = {
  revision: number;
  content_hash: string;
  deleted: boolean;
  bundle: unknown;
};

async function lockCatalog(tx: DB) {
  // Serialized clock update is held until commit: sequence order IS commit order.
  await tx.query(
    "SELECT value FROM catalog_clock WHERE singleton=true FOR UPDATE",
  );
}

async function assertSnapshotQuotes(tx: DB, b: Bundle) {
  const normalizeQuote = (value: string) =>
    value.normalize("NFKC").replace(/\s+/g, "");
  const identity = (url: string) => {
    const value = new URL(url);
    value.hash = "";
    return value.href;
  };
  const snapshots = new Map<string, { urls: string[]; searchable: string }>();
  for (const e of b.evidence) {
    let snapshot = snapshots.get(e.snapshotID);
    if (!snapshot) {
      const row = (
        await tx.query(
          "SELECT s.body,s.metadata,s.content_hash,d.fetch_url FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE s.id=$1",
          [e.snapshotID],
        )
      ).rows[0];
      if (!row)
        throw new DomainError(
          422,
          `Evidence snapshot not found: ${e.snapshotID}`,
        );
      const $ = load(row.body);
      snapshot = {
        urls: [row.fetch_url, row.metadata?.finalUrl]
          .filter(Boolean)
          .map(identity),
        searchable: normalizeQuote(
          $.root().text() +
            " " +
            $("meta")
              .map((_i, n) => $(n).attr("content") ?? "")
              .get()
              .join(" "),
        ),
      };
      snapshots.set(e.snapshotID, snapshot);
    }
    if (!snapshot.urls.includes(identity(e.sourceURL)))
      throw new DomainError(422, "Evidence URL differs from snapshot source");
    if (!snapshot.searchable.includes(normalizeQuote(e.quote)))
      throw new DomainError(
        422,
        `Evidence quote absent from snapshot: ${e.recordID}.${e.field}`,
      );
  }
}

async function writePublication(
  tx: DB,
  bundle: Bundle,
  old: StoredEvent | undefined,
  actor: string,
  reason: string,
) {
  const stored = old ? parseBundle(old.bundle) : null;
  const next = stored ? retainConfirmedFields(stored, bundle) : bundle;
  if (next !== bundle) assertEvidence(next);
  const hash = businessHash(next);
  if (old?.content_hash === hash && !old.deleted)
    return {
      eventID: next.event.id,
      revision: old.revision,
      unchanged: true as const,
    };
  const revision = (old?.revision ?? 0) + 1;
  acceptEventRevision(old?.revision ?? null, revision);
  next.revision = revision;
  next.publishedAt = new Date().toISOString();
  await tx.query(
    "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET revision=EXCLUDED.revision,bundle=EXCLUDED.bundle,content_hash=EXCLUDED.content_hash,deleted=false,updated_at=now()",
    [next.event.id, next.revision, JSON.stringify(next), hash],
  );
  await normalize(tx, next);
  await tx.query(
    "INSERT INTO event_revisions(event_id,revision,bundle,content_hash,reason,reviewer) VALUES($1,$2,$3,$4,$5,$6)",
    [next.event.id, next.revision, JSON.stringify(next), hash, reason, actor],
  );
  for (const e of next.evidence)
    await tx.query(
      "INSERT INTO accepted_facts(event_id,revision,record_id,field,evidence) VALUES($1,$2,$3,$4,$5) ON CONFLICT(event_id,revision,record_id,field) DO NOTHING",
      [next.event.id, next.revision, e.recordID, e.field, JSON.stringify(e)],
    );
  const sequence = (
    await tx.query(
      "UPDATE catalog_clock SET value=value+1 WHERE singleton=true RETURNING value",
    )
  ).rows[0].value;
  await tx.query(
    "INSERT INTO catalog_changes(sequence,event_id,revision,kind,bundle) VALUES($1,$2,$3,'upsert',$4)",
    [sequence, next.event.id, next.revision, JSON.stringify(next)],
  );
  await tx.query(
    "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,$4,'event.changed',$5)",
    [
      randomUUID(),
      `${next.event.id}:${next.revision}`,
      next.event.id,
      next.revision,
      JSON.stringify({
        eventID: next.event.id,
        revision: next.revision,
        previousRevision: old?.revision ?? 0,
      }),
    ],
  );
  await tx.query(
    "UPDATE notification_deliveries SET status='cancelled',lease_until=null,lease_token=null WHERE event_id=$1 AND status IN('pending','retry','sending')",
    [next.event.id],
  );
  await tx.query(
    "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,$2,'publish',$3,$4)",
    [randomUUID(), actor, next.event.id, reason],
  );
  return {
    eventID: next.event.id,
    revision: next.revision,
    cursor: String(sequence),
    unchanged: false as const,
  };
}

export async function publishReview(
  db: DB,
  reviewID: string,
  reviewer: string,
  reason: string,
) {
  if (!reason.trim() || !reviewer.trim())
    throw new DomainError(400, "Reviewer and reason required");
  return db.transaction(async (tx) => {
    await lockCatalog(tx);
    const review = (
      await tx.query("SELECT * FROM review_cases WHERE id=$1 FOR UPDATE", [
        reviewID,
      ])
    ).rows[0];
    if (!review) throw new DomainError(404, "Review not found");
    if (review.status === "accepted")
      return { eventID: review.event_id, alreadyPublished: true };
    if (review.status !== "pending")
      throw new DomainError(409, "Review already rejected");
    const b = parseBundle(review.proposal);
    assertEvidence(b);
    await assertSnapshotQuotes(tx, b);
    const old = (
      await tx.query("SELECT * FROM events WHERE id=$1", [b.event.id])
    ).rows[0] as StoredEvent | undefined;
    if ((old?.revision ?? 0) !== review.base_revision)
      throw new DomainError(
        409,
        "Stale base revision; rebase and review again",
      );
    const written = await writePublication(tx, b, old, reviewer, reason);
    await tx.query(
      "UPDATE review_cases SET status='accepted',reason=$2,reviewer=$3,resolved_at=now() WHERE id=$1",
      [reviewID, reason, reviewer],
    );
    if (written.unchanged)
      return {
        eventID: written.eventID,
        revision: written.revision,
        unchanged: true as const,
      };
    return {
      eventID: written.eventID,
      revision: written.revision,
      cursor: written.cursor,
    };
  });
}

export async function autoPublish(
  db: DB,
  input: unknown,
  baseRevision: number,
  receiptInput: ValidationReceipt,
) {
  const bundle = parseBundle(structuredClone(input));
  const receipt = createValidationReceipt(receiptInput);
  return db.transaction(async (tx) => {
    await lockCatalog(tx);
    const old = (
      await tx.query("SELECT * FROM events WHERE id=$1", [bundle.event.id])
    ).rows[0] as StoredEvent | undefined;
    if ((old?.revision ?? 0) !== baseRevision)
      throw new DomainError(
        409,
        "Stale base revision; rebase and review again",
      );
    const previous = old && !old.deleted ? parseBundle(old.bundle) : null;
    const issues = autoPublishIssues(bundle, receipt, previous);
    try {
      await assertSnapshotQuotes(tx, bundle);
    } catch (error) {
      if (!(error instanceof DomainError)) throw error;
      issues.push({ code: "missing_reference", message: error.message });
    }
    for (const evidence of bundle.evidence) {
      const listed = receipt.snapshotHashes.find(
        (item) => item.id === evidence.snapshotID,
      );
      if (!listed) {
        issues.push({
          code: "missing_reference",
          message: `Snapshot ${evidence.snapshotID} is not on the receipt`,
        });
        continue;
      }
      const row = (
        await tx.query("SELECT content_hash FROM source_snapshots WHERE id=$1", [
          evidence.snapshotID,
        ])
      ).rows[0];
      if (!row || row.content_hash !== listed.contentHash)
        issues.push({
          code: "missing_reference",
          message: `Snapshot ${evidence.snapshotID} hash does not match the receipt`,
        });
    }
    if (issues.length) {
      const review = await createReview(tx, bundle, baseRevision, issues);
      return {
        status: "needsReview" as const,
        id: review.id,
        eventID: review.eventID,
        issues,
      };
    }
    const written = await writePublication(
      tx,
      bundle,
      old,
      receipt.actor,
      `auto:${receipt.policyVersion}`,
    );
    if (written.unchanged)
      return {
        status: "published" as const,
        eventID: written.eventID,
        revision: written.revision,
        unchanged: true as const,
      };
    return {
      status: "published" as const,
      eventID: written.eventID,
      revision: written.revision,
      cursor: written.cursor,
    };
  });
}
export async function withdrawEvent(
  db: DB,
  eventID: string,
  baseRevision: number,
  actor: string,
  reason: string,
  replacementID?: string,
) {
  return db.transaction(async (tx) => {
    await tx.query(
      "SELECT value FROM catalog_clock WHERE singleton=true FOR UPDATE",
    );
    const old = (await tx.query("SELECT * FROM events WHERE id=$1", [eventID]))
      .rows[0];
    if (!old) throw new DomainError(404, "Event not found");
    if (old.revision !== baseRevision || old.deleted)
      throw new DomainError(409, "Stale event");
    if (
      replacementID &&
      (replacementID === eventID ||
        !(
          await tx.query("SELECT id FROM events WHERE id=$1 AND NOT deleted", [
            replacementID,
          ])
        ).rows.length)
    )
      throw new DomainError(422, "Invalid replacement");
    const revision = old.revision + 1;
    const audience = (
      await tx.query(
        'SELECT installation_id AS "installationID",performance_ids AS "performanceIDs",changes_enabled AS "changesEnabled" FROM subscriptions WHERE event_id=$1',
        [eventID],
      )
    ).rows;
    await tx.query(
      "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,$4,'event.withdrawn',$5)",
      [
        randomUUID(),
        `withdraw:${eventID}:${revision}`,
        eventID,
        revision,
        JSON.stringify({
          eventID,
          revision,
          replacementID,
          officialTitle: old.bundle.event.officialTitle,
          audience,
        }),
      ],
    );
    const tombstoneBundle = {
      ...old.bundle,
      revision,
      publishedAt: new Date().toISOString(),
    };
    await tx.query("UPDATE events SET deleted=true,revision=$2 WHERE id=$1", [
      eventID,
      revision,
    ]);
    await tx.query(
      "INSERT INTO event_revisions(event_id,revision,bundle,content_hash,reason,reviewer) VALUES($1,$2,$3,$4,$5,$6)",
      [
        eventID,
        revision,
        JSON.stringify(tombstoneBundle),
        old.content_hash,
        `Withdrawn: ${reason}`,
        actor,
      ],
    );
    const seq = (
      await tx.query(
        "UPDATE catalog_clock SET value=value+1 WHERE singleton=true RETURNING value",
      )
    ).rows[0].value;
    await tx.query(
      "INSERT INTO catalog_changes(sequence,event_id,revision,kind,replacement_id) VALUES($1,$2,$3,$4,$5)",
      [
        seq,
        eventID,
        revision,
        replacementID ? "remap" : "delete",
        replacementID ?? null,
      ],
    );
    await tx.query(
      "UPDATE notification_deliveries SET status='cancelled',lease_until=null,lease_token=null WHERE event_id=$1 AND status IN('pending','retry','sending')",
      [eventID],
    );
    await tx.query("UPDATE reminders SET enabled=false WHERE event_id=$1", [
      eventID,
    ]);
    await tx.query("DELETE FROM subscriptions WHERE event_id=$1", [eventID]);
    await tx.query(
      "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,$2,'withdraw',$3,$4)",
      [randomUUID(), actor, eventID, reason],
    );
    return { cursor: String(seq), revision };
  });
}
