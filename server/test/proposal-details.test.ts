import assert from "node:assert/strict";
import test from "node:test";
import { makeSnapshot } from "../src/ingestion/index.js";
import type { ParseResult } from "../src/ingestion/types.js";
import {
  proposeSnapshot,
  registerDocument,
  saveSnapshot,
  stableIdentity,
} from "../src/ingestion-worker.js";
import { mergeSnapshotDetails } from "../src/proposal-details.js";
import { seededBundle, testDB } from "./support.js";

test("ticket proposal materialization preserves links, products, and candidate scope", async () => {
  const db = await testDB();
  try {
    const bundle = await seededBundle(db);
    const day1 = bundle.performances[0]!.id;
    const day2 = bundle.performances[1]!.id;
    const snapshot = makeSnapshot({
      sourceDocumentId: "ticket-details",
      fetchUrl: "https://example.org/ticket-details",
      finalUrl: "https://example.org/ticket-details",
      statusCode: 200,
      headers: { "content-type": "text/html" },
      fetchedAt: "2026-09-23T00:00:00.000Z",
      body: Buffer.from("<p>DAY2 serial ticket details</p>"),
    });
    const links = [
      {
        label: "受付URL",
        url: "https://eplus.jp/serial/day2/",
        role: "application" as const,
        productNames: ["Test Single「B」"],
      },
      {
        label: "Test Single「B」",
        url: "https://example.org/products/b",
        role: "product" as const,
      },
    ];
    const parsed: ParseResult = {
      adapterId: "test.ticket-details",
      adapterVersion: "test",
      candidates: [
        {
          entityRef: { sourceKey: "test#day2-round" },
          field: "ticket.round",
          value: {
            officialName: "DAY2 serial lottery",
            kind: "lottery",
            applyStartAt: "2026-09-01T12:00:00+09:00",
            applyEndAt: "2026-09-10T23:59:00+09:00",
            applyURL: links[0].url,
            links,
            applyWindowText: "9月1日 12:00～9月10日 23:59",
            quantityLimit: "シリアル1つにつき4枚まで",
            lotteryProducts: ["Test Single「B」"],
            applicationTarget: "DAY2",
            notes: [],
          },
          applicability: { kind: "unresolved", rawText: "DAY2" },
          sourceSnapshotId: snapshot.id,
          evidence: {
            sectionPath: ["ticket"],
            locator: "#day2-round",
            rawText: "DAY2 serial ticket details",
            sourceLanguage: "ja",
          },
          extractionMethod: "dom",
          parserVersion: "test",
        },
      ],
      media: [],
      links: [],
      sections: [],
      issues: [],
    };

    const merged = await mergeSnapshotDetails(
      db,
      bundle,
      parsed,
      snapshot,
      day1,
    );
    const round = merged.ticketRounds.find(
      (candidate) => candidate.officialName === "DAY2 serial lottery",
    )!;
    assert.deepEqual(round.scope, {
      kind: "performances",
      performanceIDs: [day2],
    });
    assert.deepEqual(round.links, links);
    assert.deepEqual(round.lotteryProducts, ["Test Single「B」"]);
    assert.equal(round.applicationTarget, "DAY2");
    assert.equal(round.quantityLimit, "シリアル1つにつき4枚まで");
    assert.equal(round.applyWindowText, "9月1日 12:00～9月10日 23:59");
  } finally {
    await db.close();
  }
});

test("mergeSnapshotDetails replaces a stored round instead of keeping omitted fields", async () => {
  const db = await testDB();
  try {
    const bundle = await seededBundle(db);
    const snapshot = makeSnapshot({
      sourceDocumentId: "round-replace",
      fetchUrl: "https://example.org/round-replace",
      finalUrl: "https://example.org/round-replace",
      statusCode: 200,
      headers: { "content-type": "text/html" },
      fetchedAt: "2026-09-23T00:00:00.000Z",
      body: Buffer.from("<p>round</p>"),
    });
    const round = (
      eligibility?: string,
    ): ParseResult["candidates"][number] => ({
      entityRef: { sourceKey: "test#round" },
      field: "ticket.round",
      value: {
        officialName: "General sale",
        kind: "lottery",
        ...(eligibility ? { eligibility } : {}),
      },
      applicability: { kind: "unresolved", rawText: "unspecified" },
      sourceSnapshotId: snapshot.id,
      evidence: {
        sectionPath: ["ticket"],
        locator: "#general-sale",
        rawText: "General sale",
        sourceLanguage: "ja",
      },
      extractionMethod: "dom",
      parserVersion: "test",
    });
    const first = await mergeSnapshotDetails(
      db,
      bundle,
      {
        adapterId: "test.round",
        adapterVersion: "test",
        candidates: [round("fan club")],
        media: [],
        links: [],
        sections: [],
        issues: [],
      },
      snapshot,
    );
    const second = await mergeSnapshotDetails(
      db,
      first,
      {
        adapterId: "test.round",
        adapterVersion: "test",
        candidates: [round()],
        media: [],
        links: [],
        sections: [],
        issues: [],
      },
      snapshot,
    );
    const stored = second.ticketRounds.find(
      (candidate) => candidate.officialName === "General sale",
    )!;
    assert.equal(stored.eligibility, null);
    assert.equal(stored.id, first.ticketRounds[0]!.id);
  } finally {
    await db.close();
  }
});

test("proposeSnapshot drops a stored ticket price when the new snapshot has no ticket candidate", async () => {
  const db = await testDB();
  try {
    const url = "https://bang-dream.com/events/no-ticket-refresh/";
    const doc = await registerDocument(db, url);
    const html = `<article class="p-live-event-detail">
      <h1 class="p-live-event-detail__header-title">Fresh Show</h1>
      <div class="p-live-event-detail__content">
        <h2>日程</h2>
        <p>2026年10月10日(土)</p>
      </div>
    </article>`;
    const snapshot = await saveSnapshot(
      db,
      makeSnapshot({
        sourceDocumentId: doc.id,
        fetchUrl: url,
        finalUrl: url,
        statusCode: 200,
        headers: { "content-type": "text/html" },
        fetchedAt: "2026-09-23T00:00:00.000Z",
        body: Buffer.from(html),
      }),
    );
    const eventID = await stableIdentity(db, url, "event");
    const performanceID = await stableIdentity(
      db,
      `${url}#session:single`,
      "performance",
    );
    await db.query(
      "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,$2,$3,$4)",
      [
        eventID,
        4,
        JSON.stringify({
          schemaVersion: 1,
          publishedAt: "2026-09-01T00:00:00.000Z",
          event: {
            id: eventID,
            franchise: "bangdream",
            officialTitle: "Stale Show",
            groups: ["Stored Group"],
            eventType: "fanMeeting",
            status: "cancelled",
            primarySourceURL: url,
            timeZone: "Asia/Tokyo",
          },
          performances: [
            {
              id: performanceID,
              eventID,
              dayLabel: "single",
              localDate: "2026-10-10",
              venueName: "OLD HALL",
              venueCity: "Stored City",
              performers: ["Stored Group"],
              order: 0,
            },
          ],
          ticketTiers: [
            {
              id: "stored-tier",
              eventID,
              name: "reserved",
              priceKind: "full",
              priceJPY: 8800,
            },
          ],
          goodsCampaigns: [
            {
              id: "stored-goods",
              eventID,
              officialName: "Stored towel",
              channel: "venue",
              fulfillment: "venuePickup",
              phase: "during",
              scope: { kind: "unconfirmed" },
              mediaAssetIDs: [],
              status: "needsReview",
            },
          ],
          mediaAssets: [
            {
              id: "stored-media",
              eventID,
              kind: "keyVisual",
              originalURL: "https://example.org/old.png",
              scope: { kind: "unconfirmed" },
              sourceURL: url,
              version: 1,
            },
          ],
          evidence: [],
        }),
        "stored-hash",
      ],
    );
    const review = await proposeSnapshot(db, snapshot.id);
    const proposal = (
      await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
        review.id,
      ])
    ).rows[0].proposal;
    assert.equal(proposal.event.id, eventID);
    assert.equal(proposal.event.eventType, "live");
    assert.equal(proposal.event.status, "scheduled");
    assert.equal(proposal.performances[0].venueName, "");
    assert.equal(proposal.performances[0].venueCity, "");
    assert.deepEqual(proposal.ticketTiers, []);
    assert.deepEqual(proposal.goodsCampaigns, []);
    assert.deepEqual(proposal.mediaAssets, []);
    assert.equal(JSON.stringify(proposal).includes("8800"), false);
  } finally {
    await db.close();
  }
});
