import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";

export type UpdateTarget =
  | { kind: "catalog" }
  | { kind: "source"; sourceID: string }
  | { kind: "event"; eventID: string }
  | {
      kind: "eventSection";
      eventID: string;
      section:
        | "goods"
        | "tickets"
        | "performers"
        | "schedule"
        | "notices"
        | "media"
        | "stream";
    }
  | { kind: "card"; eventID: string; cardID: string }
  | { kind: "history"; eventID: string };

export interface UpdateJobRequest {
  target: UpdateTarget;
  idempotencyKey: string;
  fetchLatest: boolean;
  reextract: boolean;
  reason: "owner_requested" | "schedule" | "source_changed";
  kind?: string;
}

export interface UpdateJobReceipt {
  jobID: string;
  deduplicated: boolean;
  state: "queued" | "waiting";
}

/** Stable merge key for manual and scheduled work on the same target. */
export function activeJobKey(kind: string, target: UpdateTarget): string {
  switch (target.kind) {
    case "catalog":
      return `${kind}:catalog`;
    case "source":
      return `${kind}:source:${target.sourceID}`;
    case "event":
      return `${kind}:event:${target.eventID}`;
    case "eventSection":
      return `${kind}:eventSection:${target.eventID}:${target.section}`;
    case "card":
      return `${kind}:card:${target.eventID}:${target.cardID}`;
    case "history":
      return `${kind}:history:${target.eventID}`;
  }
}

export async function enqueue(
  db: DB,
  kind: string,
  payload: unknown,
  dedupeKey: string,
  runAt = new Date(),
) {
  return (
    await db.query(
      "INSERT INTO jobs(id,kind,payload,dedupe_key,run_at) VALUES($1,$2,$3,$4,$5) ON CONFLICT(dedupe_key) DO NOTHING RETURNING id",
      [randomUUID(), kind, JSON.stringify(payload), dedupeKey, runAt],
    )
  ).rows[0]?.id;
}
export async function claim(
  db: DB,
  kind: string,
  leaseSeconds = 60,
): Promise<{
  id: string;
  payload: any;
  fencing_token: string;
  attempts: number;
} | null> {
  return db.transaction(async (tx) => {
    await tx.query(
      "UPDATE jobs SET status='failed',last_error='Lease expired at retry limit' WHERE kind=$1 AND status='running' AND lease_until<now() AND attempts>=max_attempts",
      [kind],
    );
    const job = (
      await tx.query(
        "SELECT * FROM jobs WHERE kind=$1 AND attempts<max_attempts AND COALESCE(payload->>'state','')<>'waiting' AND ((status='queued' AND run_at<=now()) OR (status='running' AND lease_until<now())) ORDER BY run_at FOR UPDATE SKIP LOCKED LIMIT 1",
        [kind],
      )
    ).rows[0];
    if (!job) return null;
    const token = randomUUID();
    await tx.query(
      "UPDATE jobs SET status='running',attempts=attempts+1,fencing_token=$2,lease_until=now()+($3*interval '1 second') WHERE id=$1",
      [job.id, token, leaseSeconds],
    );
    return {
      id: String(job.id),
      payload: job.payload,
      fencing_token: token,
      attempts: Number(job.attempts) + 1,
    };
  });
}
export async function complete(db: DB, id: string, token: string) {
  return (
    (
      await db.query(
        "UPDATE jobs SET status='done',lease_until=null WHERE id=$1 AND fencing_token=$2 AND status='running' AND lease_until>now() RETURNING id",
        [id, token],
      )
    ).rows.length === 1
  );
}
export async function fail(
  db: DB,
  id: string,
  token: string,
  error: string,
  delaySeconds = 60,
) {
  await db.query(
    "UPDATE jobs SET status=CASE WHEN attempts>=max_attempts THEN 'failed' ELSE 'queued' END,last_error=$3,run_at=now()+($4*interval '1 second'),lease_until=null WHERE id=$1 AND fencing_token=$2 AND status='running' AND lease_until>now()",
    [id, token, error.slice(0, 2000), delaySeconds],
  );
}

function asObject(value: unknown): Record<string, unknown> {
  if (typeof value === "string")
    return JSON.parse(value) as Record<string, unknown>;
  if (value && typeof value === "object")
    return value as Record<string, unknown>;
  return {};
}

function assertTarget(target: UpdateTarget): void {
  switch (target.kind) {
    case "catalog":
      return;
    case "source":
      if (!target.sourceID.trim()) throw new Error("source target requires sourceID");
      return;
    case "event":
    case "history":
      if (!target.eventID.trim()) throw new Error("event target requires eventID");
      return;
    case "eventSection":
      if (!target.eventID.trim() || !target.section)
        throw new Error("section target requires eventID and section");
      return;
    case "card":
      if (!target.eventID.trim() || !target.cardID.trim())
        throw new Error("card target requires eventID and cardID");
      return;
  }
}

async function parentIdentityVisible(db: DB, eventID: string): Promise<boolean> {
  const row = (
    await db.query(
      "SELECT bundle FROM events WHERE id=$1 AND NOT deleted",
      [eventID],
    )
  ).rows[0];
  const performances = asObject(row?.bundle).performances;
  if (!Array.isArray(performances) || performances.length === 0) return false;
  return performances.every((performance) => {
    const id = asObject(performance).id;
    return typeof id === "string" && id.trim().length > 0;
  });
}

/**
 * Same idempotency key returns the same job, including after it finishes.
 * A different request for the same active target joins the in-flight job.
 * A card with no stored parent identity waits instead of skipping that dependency.
 */
export async function enqueueUpdateJob(
  db: DB,
  request: UpdateJobRequest,
): Promise<UpdateJobReceipt> {
  const idempotencyKey = request.idempotencyKey.trim();
  if (!idempotencyKey) throw new Error("idempotency key is required");
  assertTarget(request.target);
  const kind = request.kind ?? "update";
  const activeKey = activeJobKey(kind, request.target);
  const waiting =
    request.target.kind === "card" &&
    !(await parentIdentityVisible(db, request.target.eventID));
  const dependency = waiting
    ? { status: "unresolved" as const, reason: "parent_identity_not_visible" as const }
    : request.target.kind === "card"
      ? { status: "resolved" as const, source: "stored_event" as const }
      : null;
  const state: UpdateJobReceipt["state"] = waiting ? "waiting" : "queued";
  const payload = {
    target: request.target,
    activeKey,
    idempotencyKey,
    fetchLatest: request.fetchLatest,
    reextract: request.reextract,
    reason: request.reason,
    state,
    ...(dependency ? { dependency } : {}),
  };
  return db.transaction(async (tx) => {
    await tx.query("LOCK TABLE jobs IN SHARE ROW EXCLUSIVE MODE");
    const dedupeKey = `idempotency:${idempotencyKey}`;
    const byKey = (
      await tx.query(
        "SELECT id, payload, status FROM jobs WHERE dedupe_key=$1",
        [dedupeKey],
      )
    ).rows[0];
    if (byKey) return resumeReadyCard(tx, byKey, request.target);
    const active = (
      await tx.query(
        "SELECT id, payload, status FROM jobs WHERE kind=$1 AND status IN ('queued','running') AND payload->>'activeKey'=$2 ORDER BY created_at LIMIT 1",
        [kind, activeKey],
      )
    ).rows[0];
    if (active) return resumeReadyCard(tx, active, request.target);
    const id = randomUUID();
    await tx.query(
      "INSERT INTO jobs(id,kind,payload,dedupe_key,run_at) VALUES($1,$2,$3,$4,CASE WHEN $5::boolean THEN 'infinity'::timestamptz ELSE now() END)",
      [id, kind, JSON.stringify(payload), dedupeKey, waiting],
    );
    return { jobID: id, deduplicated: false, state };
  });
}

/** A waiting card stays one job; stored parent ids let that same job leave the wait. */
async function resumeReadyCard(
  db: DB,
  row: Record<string, any>,
  target: UpdateTarget,
): Promise<UpdateJobReceipt> {
  const payload = asObject(row.payload);
  if (
    payload.state === "waiting" &&
    row.status === "queued" &&
    target.kind === "card" &&
    (await parentIdentityVisible(db, target.eventID))
  ) {
    const next = {
      ...payload,
      state: "queued",
      dependency: { status: "resolved", source: "stored_event" },
    };
    await db.query(
      "UPDATE jobs SET payload=$2, run_at=now() WHERE id=$1 AND status='queued'",
      [row.id, JSON.stringify(next)],
    );
    return { jobID: String(row.id), deduplicated: true, state: "queued" };
  }
  return receipt(row.id, row.payload, true);
}

function receipt(
  id: unknown,
  payload: unknown,
  deduplicated: boolean,
): UpdateJobReceipt {
  const state = asObject(payload).state === "waiting" ? "waiting" : "queued";
  return { jobID: String(id), deduplicated, state };
}
