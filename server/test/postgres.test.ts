import test from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { PostgresDB, migrate } from "../src/db.js";
import { seededBundle } from "./support.js";
import { createReview, publishReview } from "../src/publisher.js";
import { createApp } from "../src/api.js";

test(
  "PostgreSQL 18 concurrent publishers expose a contiguous committed catalog",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const db = new PostgresDB(process.env.TEST_DATABASE_URL!);
    const app = createApp(db, {
      adminToken: "integration-test-only-32-characters",
    });
    try {
      await migrate(db, resolve("db/migrations"));
      const version = (await db.query("SHOW server_version")).rows[0]
        .server_version;
      assert.match(version, /^18\./);
      const before = (await app.inject("/v1/catalog/bootstrap")).json();
      const a = await seededBundle(db),
        b = await seededBundle(db);
      const ra = await createReview(db, a, 0),
        rb = await createReview(db, b, 0);
      await Promise.all([
        publishReview(db, ra.id, "CI", "Concurrent A"),
        publishReview(db, rb.id, "CI", "Concurrent B"),
      ]);
      const changes = (
        await app.inject(`/v1/catalog/changes?cursor=${before.cursor}`)
      ).json();
      assert.equal(changes.changes.length, 2);
      assert.equal(
        BigInt(changes.changes[1].sequence) -
          BigInt(changes.changes[0].sequence),
        1n,
      );
      const bootstrap = (await app.inject("/v1/catalog/bootstrap")).json();
      assert.equal(bootstrap.cursor, changes.cursor);
      assert.ok(bootstrap.events.some((e: any) => e.event.id === a.event.id));
      assert.ok(bootstrap.events.some((e: any) => e.event.id === b.event.id));
    } finally {
      await app.close();
      await db.close();
    }
  },
);
