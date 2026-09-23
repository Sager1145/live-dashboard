import assert from "node:assert/strict";
import test from "node:test";
import { makeSnapshot } from "../src/ingestion/index.js";
import type { ParseResult } from "../src/ingestion/types.js";
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
