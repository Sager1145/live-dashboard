import { randomUUID } from "node:crypto";
import type { DB } from "./db.js";
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
        "SELECT * FROM jobs WHERE kind=$1 AND attempts<max_attempts AND ((status='queued' AND run_at<=now()) OR (status='running' AND lease_until<now())) ORDER BY run_at FOR UPDATE SKIP LOCKED LIMIT 1",
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
