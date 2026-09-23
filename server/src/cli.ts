import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { scheduleMedia, runMediaJob } from "./media-worker.js";
import { blobStoreFromEnv } from "./storage/index.js";
import { PostgresDB, migrate } from "./db.js";
import {
  parserConfigurationVersion,
  registerDocument,
  importSnapshot,
  proposeSnapshot,
  augmentReviewFromSnapshot,
  scheduleSources,
  runFetchJob,
  runParseJob,
} from "./ingestion-worker.js";
import { createReview, publishReview } from "./publisher.js";
import {
  scheduleNotifications,
  deliverNotifications,
} from "./notification-worker.js";
import { ApnsTransport } from "./notifications/apns.js";
import { bundleSchema } from "./contracts.js";
import { z } from "zod";
import { enqueue } from "./queue.js";

const blobs = blobStoreFromEnv();
const [command, ...args] = process.argv.slice(2);
if (command === "schema") {
  await writeFile(
    resolve("../schema/live-dashboard.schema.json"),
    JSON.stringify(z.toJSONSchema(bundleSchema), null, 2) + "\n",
  );
  process.exit(0);
}
const db = new PostgresDB(
  process.env.DATABASE_URL ??
    "postgresql://livedash:livedash@localhost:5432/livedash",
);
let stopped = false;
for (const signal of ["SIGINT", "SIGTERM"])
  process.on(signal, () => {
    stopped = true;
  });
const wait = () => new Promise((r) => setTimeout(r, 1000));
try {
  switch (command) {
    case "migrate":
      await migrate(db, resolve("db/migrations"));
      console.log("Migrations applied");
      break;
    case "register": {
      if (!args[0]) throw new Error("register <https-url>");
      console.log(await registerDocument(db, args[0]));
      break;
    }
    case "seed": {
      const raw = JSON.parse(
        await readFile(resolve("../fixtures/sources-manifest.json"), "utf8"),
      );
      let count = 0;
      for (const event of raw.events ?? raw.samples ?? [])
        for (const source of event.sources ?? []) {
          await registerDocument(db, source.url);
          count++;
        }
      console.log({ registered: count, enabled: false });
      break;
    }
    case "source-policy": {
      if (!args[0] || !args[1])
        throw new Error("source-policy <origin> <reviewed-policy.json>");
      const policy = JSON.parse(await readFile(args[1], "utf8"));
      if (
        policy.enabled &&
        (!policy.robotsCheckedAt ||
          !policy.termsReviewedAt ||
          policy.reviewStatus !== "approved")
      )
        throw new Error(
          "Enabled policy requires dated robots and terms review",
        );
      await db.query("UPDATE source_origins SET policy=$2 WHERE origin=$1", [
        args[0],
        JSON.stringify(policy),
      ]);
      console.log("Policy updated. Enable individual documents separately.");
      break;
    }
    case "enable-document": {
      if (!args[0]) throw new Error("enable-document <uuid>");
      await db.query(
        "UPDATE source_documents SET enabled=true,next_fetch_at=now() WHERE id=$1",
        [args[0]],
      );
      break;
    }
    case "import-snapshot": {
      if (!args[0] || !args[1])
        throw new Error("import-snapshot <https-url> <html-path>");
      const r = await importSnapshot(db, args[0], args[1]);
      console.log({
        snapshotID: r.snapshot.id,
        adapter: r.result.adapterId,
        candidates: r.result.candidates.length,
        issues: r.result.issues,
      });
      break;
    }
    case "reparse": {
      if (!args[0]) throw new Error("reparse <snapshot-uuid>");
      console.log(
        await enqueue(
          db,
          "parse",
          { snapshotID: args[0] },
          `parse:${args[0]}:${parserConfigurationVersion}`,
        ),
      );
      break;
    }
    case "propose": {
      if (!args[0]) throw new Error("propose <snapshot-uuid>");
      console.log(await proposeSnapshot(db, args[0]));
      break;
    }
    case "augment-review": {
      if (!args[0] || !args[1])
        throw new Error(
          "augment-review <review-uuid> <snapshot-uuid> [explicit-performance-uuid]",
        );
      console.log(
        await augmentReviewFromSnapshot(db, args[0], args[1], args[2]),
      );
      break;
    }
    case "review-json": {
      if (!args[0])
        throw new Error("review-json <bundle-json-path> <base-revision>");
      console.log(
        await createReview(
          db,
          JSON.parse(await readFile(args[0], "utf8")),
          Number(args[1] ?? 0),
        ),
      );
      break;
    }
    case "publish": {
      if (!args[0] || !args[1] || !args[2])
        throw new Error(
          "publish <review-uuid> <reviewer> <reason> (all evidence must be explicitly verified)",
        );
      console.log(await publishReview(db, args[0], args[1], args[2]));
      break;
    }
    case "scheduler":
      do {
        await scheduleSources(db);
        if (blobs) await scheduleMedia(db);
        if (args.includes("--once")) break;
        await wait();
      } while (!stopped);
      break;
    case "worker":
      do {
        const fetched = await runFetchJob(db);
        const parsed = await runParseJob(db);
        const media = blobs ? await runMediaJob(db, { blobs }) : false;
        const worked = fetched || parsed || media;
        if (args.includes("--once")) break;
        if (!worked) await wait();
      } while (!stopped);
      break;
    case "notify": {
      const privateKey = process.env.APNS_KEY_FILE
        ? await readFile(process.env.APNS_KEY_FILE, "utf8")
        : undefined;
      const transports = {
        sandbox: new ApnsTransport({
          environment: "development",
          credentials: {
            teamID: process.env.APNS_TEAM_ID,
            keyID: process.env.APNS_KEY_ID,
            topic: process.env.APNS_TOPIC,
            privateKey,
          },
          maxAttempts: 1,
        }),
        production: new ApnsTransport({
          environment: "production",
          credentials: {
            teamID: process.env.APNS_TEAM_ID,
            keyID: process.env.APNS_KEY_ID,
            topic: process.env.APNS_TOPIC,
            privateKey,
          },
          maxAttempts: 1,
        }),
      };
      do {
        await scheduleNotifications(db);
        if (process.env.NOTIFICATIONS_ENABLED === "true")
          await deliverNotifications(
            db,
            (environment) =>
              transports[
                environment === "development" ? "sandbox" : "production"
              ],
          );
        if (args.includes("--once")) break;
        await wait();
      } while (!stopped);
      break;
    }
    default:
      console.log(
        "Commands: migrate | seed | register | source-policy | enable-document | import-snapshot | propose | augment-review | reparse | review-json | publish | scheduler | worker | notify | schema",
      );
  }
} finally {
  await db.close();
}
