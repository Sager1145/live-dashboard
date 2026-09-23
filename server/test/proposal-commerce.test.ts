import test from "node:test";
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { testDB, seededBundle } from "./support.js";
import { createReview } from "../src/publisher.js";
import {
  importSnapshot,
  augmentReviewFromSnapshot,
} from "../src/ingestion-worker.js";
import { createApp } from "../src/api.js";
const samples = [
  [
    "https://bushiroad-store.com/pages/bd_13th-live-day1-poppinparty",
    "BD01-goods-day1.html",
  ],
  ["https://lovelive.fannect.jp/collections/ll-48-01", "LL03-goods.html"],
  ["https://lovelive.fannect.jp/collections/ll-47-01", "LL08-goods.html"],
  ["https://lovelive.fannect.jp/collections/ll-43-03", "LL10-goods.html"],
];
test("commerce fixtures retain campaign/product/variant relations and price evidence through publication", async () => {
  const db = await testDB();
  const adminToken = "commerce-fixture-test-32-characters";
  const headers = { authorization: `Bearer ${adminToken}` };
  const app = createApp(db, { adminToken });
  try {
    for (const [url, file] of samples) {
      const b = await seededBundle(db);
      const review = await createReview(db, b, 0);
      const snapshot = await importSnapshot(
        db,
        url!,
        resolve("tests/fixtures/research", file!),
      );
      await augmentReviewFromSnapshot(
        db,
        review.id,
        snapshot.snapshot.id,
        b.performances[0]!.id,
      );
      const proposal = (
        await db.query("SELECT proposal FROM review_cases WHERE id=$1", [
          review.id,
        ])
      ).rows[0].proposal;
      assert.ok(proposal.goodsCampaigns.length > 0, file);
      assert.ok(proposal.products.length > 0, file);
      for (const product of proposal.products) {
        assert.ok(
          proposal.goodsCampaigns.some((c: any) => c.id === product.campaignID),
        );
        if (product.amount) assert.equal(product.amount.currency, "JPY");
      }
      await app.inject({
        method: "POST",
        url: `/admin/reviews/${review.id}/verify`,
        headers,
        payload: {
          reason:
            "Synthetic event association for regression; fixture prices reviewed separately",
        },
      });
      const published = await app.inject({
        method: "POST",
        url: `/admin/reviews/${review.id}/publish`,
        headers,
        payload: { reason: "Fixture-only commerce relationships" },
      });
      assert.equal(published.statusCode, 200, `${file}: ${published.body}`);
    }
  } finally {
    await app.close();
    await db.close();
  }
});
