import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { testDB } from "./support.js";
import {
  importSnapshot,
  proposeSnapshot,
  saveSnapshot,
  registerDocument,
  augmentReviewFromSnapshot,
  runParseJob,
} from "../src/ingestion-worker.js";
import { enqueue } from "../src/queue.js";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import { createApp } from "../src/api.js";
const token = "vertical-slice-test-admin-credential";

test("real BD01 and LL01 snapshots flow through review/API; correction keeps identities and unrelated days", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken: token });
  const headers = { authorization: `Bearer ${token}` };
  try {
    const samples = [
      {
        url: "https://bang-dream.com/13th-live/",
        file: "bangdream_13th_live_hub.html",
        dates: ["2026-10-10", "2026-10-11", "2026-10-12"],
      },
      {
        url: "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
        file: "lovelive_detail_15th_lovelivefest.html",
        dates: ["2026-11-14", "2026-11-15"],
      },
    ];
    for (const sample of samples) {
      const imported = await importSnapshot(
        db,
        sample.url,
        resolve("tests/fixtures/snapshots", sample.file),
      );
      const review = await proposeSnapshot(db, imported.snapshot.id);
      assert.equal(review.performanceCount, sample.dates.length);
      if (sample.file.startsWith("bangdream")) {
        const proposal = (
          await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
            review.id,
          ])
        ).rows[0].proposal;
        for (let day = 1; day <= 3; day++) {
          const child = await importSnapshot(
            db,
            `https://bang-dream.com/events/13th-live-day${day}/`,
            resolve(
              `tests/fixtures/snapshots/bangdream_13th_live_day${day}.html`,
            ),
          );
          await augmentReviewFromSnapshot(
            db,
            review.id,
            child.snapshot.id,
            proposal.performances.find((p: any) => p.dayLabel === `DAY${day}`)
              .id,
          );
        }
        const augmented = (
          await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
            review.id,
          ])
        ).rows[0].proposal;
        for (const p of augmented.performances) {
          const rounds = augmented.ticketRounds.filter(
            (r: any) =>
              r.scope.kind === "performances" &&
              r.scope.performanceIDs.includes(p.id),
          );
          assert.ok(rounds.length > 0, `Missing ${p.dayLabel} rounds`);
          for (const r of rounds)
            assert.deepEqual(r.scope.performanceIDs, [p.id]);
        }
        assert.ok(augmented.goodsCampaigns.length > 0);
        assert.ok(augmented.ticketTiers.length > 0);
        assert.equal(
          augmented.ticketOffers.length,
          0,
          "No inferred cross-product ticket relationships",
        );
      }
      const unreviewed = await app.inject({
        method: "POST",
        url: `/admin/reviews/${review.id}/publish`,
        headers,
        payload: { reason: "Must fail before verification" },
      });
      assert.equal(unreviewed.statusCode, 422);
      const verified = await app.inject({
        method: "POST",
        url: `/admin/reviews/${review.id}/verify`,
        headers,
        payload: {
          reason: "Test oracle: inspected source dates/venue and title",
        },
      });
      assert.equal(verified.statusCode, 200);
      const published = await app.inject({
        method: "POST",
        url: `/admin/reviews/${review.id}/publish`,
        headers,
        payload: { reason: "Fixture-only integration publication" },
      });
      assert.equal(published.statusCode, 200, published.body);
      const detail = (await app.inject(`/v1/events/${review.eventID}`)).json();
      assert.deepEqual(
        detail.performances.map((p: any) => p.localDate),
        sample.dates,
      );
    }
    const bootstrap = (await app.inject("/v1/catalog/bootstrap")).json();
    assert.equal(bootstrap.events.length, 2);
    const original = bootstrap.events.find(
      (b: any) => b.event.franchise === "bangdream",
    );
    assert.equal(original.performances[0].performers[0], "Poppin'Party");
    assert.equal(original.performances[1].performers[0], "夢限大みゅーたいぷ");
    const linkedSnapshot = (
      await db.query(
        "SELECT s.id FROM source_snapshots s JOIN source_documents d ON d.id=s.document_id WHERE d.fetch_url=$1",
        ["https://bang-dream.com/events/13th-live-day1/"],
      )
    ).rows[0];
    await enqueue(
      db,
      "parse",
      { snapshotID: linkedSnapshot.id },
      "test-linked-day-replay",
    );
    await runParseJob(db);
    const linkedReview = (
      await db.query(
        "SELECT * FROM review_cases WHERE status='pending' ORDER BY created_at DESC LIMIT 1",
      )
    ).rows[0];
    assert.equal(
      linkedReview.event_id,
      original.event.id,
      "Day source replay must not create another event",
    );
    assert.equal(
      linkedReview.proposal.event.officialTitle,
      original.event.officialTitle,
    );
    assert.equal(linkedReview.proposal.performances.length, 3);
    assert.equal(
      (await app.inject("/v1/catalog/bootstrap")).json().events.length,
      2,
      "Replay stays a review and preserves catalog",
    );
    const html = await readFile(
      resolve("tests/fixtures/snapshots/bangdream_13th_live_hub.html"),
      "utf8",
    );
    const corrected = html.replace(
      "2026年10月10日(土)　開場16:30／開演18:00",
      "2026年10月10日(土)　開場16:30／開演18:30",
    );
    assert.notEqual(corrected, html);
    const doc = await registerDocument(db, samples[0]!.url);
    const snapshot = await saveSnapshot(
      db,
      makeSnapshot({
        sourceDocumentId: doc.id,
        fetchUrl: doc.fetch_url,
        finalUrl: doc.fetch_url,
        statusCode: 200,
        headers: { "x-fixture-purpose": "synthetic-correction-test-only" },
        body: Buffer.from(corrected),
      }),
    );
    const review = await proposeSnapshot(db, snapshot.id);
    await app.inject({
      method: "POST",
      url: `/admin/reviews/${review.id}/verify`,
      headers,
      payload: {
        reason: "Synthetic test correction, not an official announcement",
      },
    });
    const pub = await app.inject({
      method: "POST",
      url: `/admin/reviews/${review.id}/publish`,
      headers,
      payload: { reason: "Synthetic correction regression" },
    });
    assert.equal(pub.statusCode, 200, pub.body);
    const changed = (await app.inject(`/v1/events/${review.eventID}`)).json();
    assert.deepEqual(
      changed.performances.map((p: any) => p.id),
      original.performances.map((p: any) => p.id),
    );
    assert.equal(
      Date.parse(changed.performances[0].startAt),
      Date.parse("2026-10-10T18:30:00+09:00"),
    );
    assert.equal(
      changed.performances[1].startAt,
      original.performances[1].startAt,
    );
    const delta = (
      await app.inject(`/v1/catalog/changes?cursor=${bootstrap.cursor}`)
    ).json();
    assert.equal(delta.changes.length, 1);
    assert.equal(delta.changes[0].eventID, original.event.id);
  } finally {
    await app.close();
    await db.close();
  }
});

test("tour proposals retain each official venue and date precision without borrowing the first stop", async () => {
  const db = await testDB();
  try {
    const source = await importSnapshot(
      db,
      "https://bang-dream.com/events/roselia-10th-anniversary-live-tour/",
      resolve("tests/fixtures/research/BD05.html"),
    );
    const review = await proposeSnapshot(db, source.snapshot.id);
    const b = (
      await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
        review.id,
      ])
    ).rows[0].proposal;
    assert.deepEqual(
      b.performances.map((p: any) => p.venueName),
      [
        "TOYOTA ARENA TOKYO",
        "愛知県芸術劇場 大ホール",
        "仙台サンプラザホール",
        "福岡サンパレス",
      ],
    );
    assert.ok(
      b.performances.every(
        (p: any) => p.precision === "date" && p.startAt === null,
      ),
    );
  } finally {
    await db.close();
  }
});
