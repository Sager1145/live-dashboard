/** Explicit local preview only. Never runs from server startup or production seed. */
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { randomBytes } from "node:crypto";
import { PostgresDB, migrate } from "../src/db.js";
import { createApp } from "../src/api.js";
import {
  importSnapshot,
  proposeSnapshot,
  augmentReviewFromSnapshot,
} from "../src/ingestion-worker.js";
const connection = process.env.PREVIEW_DATABASE_URL;
if (!connection || !new URL(connection).pathname.endsWith("_preview"))
  throw new Error(
    "PREVIEW_DATABASE_URL must point to an isolated *_preview database",
  );
const db = new PostgresDB(connection);
await migrate(db, resolve("db/migrations"));
const adminToken = randomBytes(32).toString("hex");
const app = createApp(db, { adminToken });
const headers = { authorization: `Bearer ${adminToken}` };
const details = [];
for (const [url, file] of [
  ["https://bang-dream.com/13th-live/", "bangdream_13th_live_hub.html"],
  [
    "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
    "lovelive_detail_15th_lovelivefest.html",
  ],
]) {
  const { snapshot } = await importSnapshot(
    db,
    url!,
    resolve("tests/fixtures/snapshots", file!),
  );
  const review = await proposeSnapshot(db, snapshot.id);
  if (file!.startsWith("bangdream")) {
    const proposal = (
      await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
        review.id,
      ])
    ).rows[0].proposal;
    for (let day = 1; day <= 3; day++) {
      const child = await importSnapshot(
        db,
        `https://bang-dream.com/events/13th-live-day${day}/`,
        resolve(`tests/fixtures/snapshots/bangdream_13th_live_day${day}.html`),
      );
      await augmentReviewFromSnapshot(
        db,
        review.id,
        child.snapshot.id,
        proposal.performances.find((p: any) => p.dayLabel === `DAY${day}`).id,
      );
    }
    const goods = await importSnapshot(
      db,
      "https://bushiroad-store.com/pages/bd_13th-live-day1-poppinparty",
      resolve("tests/fixtures/research/BD01-goods-day1.html"),
    );
    await augmentReviewFromSnapshot(
      db,
      review.id,
      goods.snapshot.id,
      proposal.performances.find((p: any) => p.dayLabel === "DAY1").id,
    );
  }
  const verified = await app.inject({
    method: "POST",
    url: `/admin/reviews/${review.id}/verify`,
    headers,
    payload: {
      reason:
        "Local preview of recorded official HTML. Date/title evidence regression reviewed; unresolved scopes remain unavailable as actions.",
    },
  });
  if (verified.statusCode !== 200) throw new Error(verified.body);
  const published = await app.inject({
    method: "POST",
    url: `/admin/reviews/${review.id}/publish`,
    headers,
    payload: {
      reason:
        "Isolated local preview from source snapshots; not a production catalog or current availability guarantee.",
    },
  });
  if (published.statusCode !== 200) throw new Error(published.body);
  details.push(published.json());
}
await mkdir("../.runtime", { recursive: true });
await writeFile(
  "../.runtime/preview-env.json",
  JSON.stringify(
    {
      databaseURL: connection,
      adminToken,
      api: "http://127.0.0.1:4318",
      events: details,
    },
    null,
    2,
  ),
  { mode: 0o600 },
);
await app.close();
await db.close();
console.log({
  prepared: details,
  configuration: resolve("../.runtime/preview-env.json"),
});
