import { PGlite } from "@electric-sql/pglite";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { migrate, type DB } from "../src/db.js";
import { parseBundle, type Bundle } from "../src/contracts.js";
export async function testDB(): Promise<DB> {
  const pg = new PGlite();
  function adapt(client: any, inTx = false): DB {
    return {
      query: async (sql, values = []) => {
        if (!values.length && sql.includes(";")) {
          const results = await client.exec(sql);
          return results.at(-1) ?? { rows: [] };
        }
        const r = await client.query(sql, values);
        return { rows: r.rows, rowCount: r.affectedRows };
      },
      transaction: async (fn) =>
        inTx
          ? fn(adapt(client, true))
          : client.transaction((tx: any) => fn(adapt(tx, true))),
      close: async () => pg.close(),
    };
  }
  const db = adapt(pg);
  await migrate(db, resolve("db/migrations"));
  return db;
}
export async function seededBundle(db: DB): Promise<Bundle> {
  const origin = randomUUID(),
    doc = randomUUID(),
    snapshot = randomUUID(),
    eventID = randomUUID(),
    p1 = randomUUID(),
    p2 = randomUUID();
  await db.query(
    "INSERT INTO source_origins(id,origin,policy) VALUES($1,$2,$3)",
    [origin, `https://${origin}.example.org`, "{}"],
  );
  await db.query(
    "INSERT INTO source_documents(id,origin_id,fetch_url,identity_url) VALUES($1,$2,$3,$3)",
    [doc, origin, `https://${origin}.example.org/live`],
  );
  await db.query(
    "INSERT INTO source_snapshots(id,document_id,content_hash,body,metadata) VALUES($1,$2,$3,$4,$5)",
    [
      snapshot,
      doc,
      "testhash",
      "Synthetic integration fixture, never production.",
      "{}",
    ],
  );
  const date = "2027-01-01T00:00:00Z";
  const evidence = (recordID: string, field: string) => ({
    id: randomUUID(),
    recordID,
    field,
    sourceURL: `https://${origin}.example.org/live`,
    quote: "Synthetic integration fixture",
    snapshotID: snapshot,
    locator: "test",
    observedAt: date,
    verifiedAt: date,
    verification: "confirmed",
    adapterVersion: "test",
    performanceIDs: [],
  });
  return parseBundle({
    schemaVersion: 1,
    publishedAt: date,
    event: {
      id: eventID,
      franchise: "bangdream",
      officialTitle: "Synthetic test event",
      groups: ["Test"],
      eventType: "live",
      status: "scheduled",
      primarySourceURL: "https://example.org/live",
      timeZone: "Asia/Tokyo",
    },
    performances: [p1, p2].map((id, i) => ({
      id,
      eventID,
      dayLabel: `DAY${i + 1}`,
      localDate: `2027-01-0${i + 1}`,
      venueName: "Test venue",
      venueCity: "",
      performers: ["Test"],
      order: i,
    })),
    evidence: [
      evidence(eventID, "officialTitle"),
      ...[p1, p2].flatMap((id) => [
        evidence(id, "localDate"),
        evidence(id, "venueName"),
      ]),
    ],
  });
}
