import { load } from "cheerio";
import { createHash, randomUUID } from "node:crypto";
import {
  assertEvidence,
  parseBundle,
  DomainError,
  type Bundle,
} from "./contracts.js";
import type { DB } from "./db.js";
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
export async function publishReview(
  db: DB,
  reviewID: string,
  reviewer: string,
  reason: string,
) {
  if (!reason.trim() || !reviewer.trim())
    throw new DomainError(400, "Reviewer and reason required");
  return db.transaction(async (tx) => {
    // Serialized clock update is held until commit: sequence order IS commit order.
    await tx.query(
      "SELECT value FROM catalog_clock WHERE singleton=true FOR UPDATE",
    );
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
            "SELECT s.body,s.metadata,d.fetch_url FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE s.id=$1",
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
          urls: [row.fetch_url, row.metadata.finalUrl]
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
    const old = (
      await tx.query("SELECT * FROM events WHERE id=$1", [b.event.id])
    ).rows[0];
    if ((old?.revision ?? 0) !== review.base_revision)
      throw new DomainError(
        409,
        "Stale base revision; rebase and review again",
      );
    const hash = businessHash(b);
    if (old?.content_hash === hash && !old.deleted) {
      await tx.query(
        "UPDATE review_cases SET status='accepted',reason=$2,reviewer=$3,resolved_at=now() WHERE id=$1",
        [reviewID, reason, reviewer],
      );
      return { eventID: b.event.id, revision: old.revision, unchanged: true };
    }
    b.revision = (old?.revision ?? 0) + 1;
    b.publishedAt = new Date().toISOString();
    await tx.query(
      "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,$2,$3,$4) ON CONFLICT(id) DO UPDATE SET revision=EXCLUDED.revision,bundle=EXCLUDED.bundle,content_hash=EXCLUDED.content_hash,deleted=false,updated_at=now()",
      [b.event.id, b.revision, JSON.stringify(b), hash],
    );
    await normalize(tx, b);
    await tx.query(
      "INSERT INTO event_revisions(event_id,revision,bundle,content_hash,reason,reviewer) VALUES($1,$2,$3,$4,$5,$6)",
      [b.event.id, b.revision, JSON.stringify(b), hash, reason, reviewer],
    );
    for (const e of b.evidence)
      await tx.query(
        "INSERT INTO accepted_facts(event_id,revision,record_id,field,evidence) VALUES($1,$2,$3,$4,$5) ON CONFLICT(event_id,revision,record_id,field) DO NOTHING",
        [b.event.id, b.revision, e.recordID, e.field, JSON.stringify(e)],
      );
    const sequence = (
      await tx.query(
        "UPDATE catalog_clock SET value=value+1 WHERE singleton=true RETURNING value",
      )
    ).rows[0].value;
    await tx.query(
      "INSERT INTO catalog_changes(sequence,event_id,revision,kind,bundle) VALUES($1,$2,$3,'upsert',$4)",
      [sequence, b.event.id, b.revision, JSON.stringify(b)],
    );
    await tx.query(
      "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,$4,'event.changed',$5)",
      [
        randomUUID(),
        `${b.event.id}:${b.revision}`,
        b.event.id,
        b.revision,
        JSON.stringify({
          eventID: b.event.id,
          revision: b.revision,
          previousRevision: old?.revision ?? 0,
        }),
      ],
    );
    await tx.query(
      "UPDATE notification_deliveries SET status='cancelled',lease_until=null,lease_token=null WHERE event_id=$1 AND status IN('pending','retry','sending')",
      [b.event.id],
    );
    await tx.query(
      "UPDATE review_cases SET status='accepted',reason=$2,reviewer=$3,resolved_at=now() WHERE id=$1",
      [reviewID, reason, reviewer],
    );
    await tx.query(
      "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,$2,'publish',$3,$4)",
      [randomUUID(), reviewer, b.event.id, reason],
    );
    return {
      eventID: b.event.id,
      revision: b.revision,
      cursor: String(sequence),
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
