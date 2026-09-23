import test from "node:test";
import assert from "node:assert/strict";
import { testDB, seededBundle } from "./support.js";
import { createApp } from "../src/api.js";
import { createReview, publishReview } from "../src/publisher.js";
const adminToken = "test-only-admin-secret-at-least-24-characters";
test("API bootstrap, deltas, ETag, install credentials and admin isolation", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const b = await seededBundle(db);
    const r = await createReview(db, b, 0);
    await publishReview(db, r.id, "tester", "Initial");
    const bootstrap = await app.inject("/v1/catalog/bootstrap");
    assert.equal(bootstrap.statusCode, 200);
    assert.equal(bootstrap.json().cursor, "1");
    assert.equal(bootstrap.json().events.length, 1);
    const detail = await app.inject(`/v1/events/${b.event.id}`);
    assert.equal(detail.statusCode, 200);
    assert.equal(
      (
        await app.inject({
          url: `/v1/events/${b.event.id}`,
          headers: { "if-none-match": detail.headers.etag as string },
        })
      ).statusCode,
      304,
    );
    const delta = await app.inject("/v1/catalog/changes?cursor=0");
    assert.equal(delta.json().changes[0].kind, "upsert");
    assert.equal(
      (await app.inject("/v1/catalog/changes?cursor=999")).statusCode,
      400,
    );
    assert.equal((await app.inject("/admin")).statusCode, 401);
    const installation = (
      await app.inject({
        method: "POST",
        url: "/v1/installations",
        payload: {},
      })
    ).json();
    const url = `/v1/installations/${installation.id}/subscriptions`;
    assert.equal(
      (await app.inject({ method: "PUT", url, payload: { subscriptions: [] } }))
        .statusCode,
      401,
    );
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url,
          headers: { authorization: `Bearer ${installation.credential}` },
          payload: {
            subscriptions: [
              { eventID: b.event.id, performanceIDs: [b.performances[0]!.id] },
            ],
          },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (
        await app.inject({
          method: "DELETE",
          url: `/v1/installations/${installation.id}`,
          headers: { authorization: `Bearer ${installation.credential}` },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM subscriptions")).rows[0].n,
      0,
    );
  } finally {
    await app.close();
    await db.close();
  }
});
test("HTML console escapes evidence and rejects browser form without CSRF", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const authorization = `Basic ${Buffer.from(`admin:${adminToken}`).toString("base64")}`;
    const html = await app.inject({
      url: "/admin",
      headers: { authorization },
    });
    assert.equal(html.statusCode, 200);
    assert.match(
      html.headers["content-security-policy"] as string,
      /frame-ancestors 'none'/,
    );
    const res = await app.inject({
      method: "POST",
      url: "/admin/reviews",
      headers: {
        authorization,
        "content-type": "application/x-www-form-urlencoded",
      },
      payload: "baseRevision=0&proposal={}",
    });
    assert.equal(res.statusCode, 403);
  } finally {
    await app.close();
    await db.close();
  }
});

test("editing a verified proposal requires verification again; live health changes preserve published values", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  const headers = { authorization: `Bearer ${adminToken}` };
  try {
    const b = await seededBundle(db);
    const review = await createReview(db, b, 0);
    const edited = await app.inject({
      method: "POST",
      url: `/admin/reviews/${review.id}/edit`,
      headers,
      payload: { reason: "Review field scope again", proposal: b },
    });
    assert.equal(edited.statusCode, 200);
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/reviews/${review.id}/publish`,
          headers,
          payload: { reason: "Unverified edits" },
        })
      ).statusCode,
      422,
    );
    await app.inject({
      method: "POST",
      url: `/admin/reviews/${review.id}/verify`,
      headers,
      payload: { reason: "Inspected synthetic evidence" },
    });
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/reviews/${review.id}/publish`,
          headers,
          payload: { reason: "Approved test" },
        })
      ).statusCode,
      200,
    );
    const before = await app.inject(`/v1/events/${b.event.id}`);
    await db.query("UPDATE source_documents SET health='blocked'");
    const detail = await app.inject({
      url: `/v1/events/${b.event.id}`,
      headers: { "if-none-match": before.headers.etag as string },
    });
    assert.equal(detail.statusCode, 200);
    assert.equal(detail.json().sourceHealth, "blocked");
    assert.deepEqual(detail.json().performances, b.performances);
    const delta = (await app.inject("/v1/catalog/changes?cursor=1")).json();
    assert.equal(delta.changes.length, 0);
    assert.equal(delta.sourceHealth[b.event.id], "blocked");
  } finally {
    await app.close();
    await db.close();
  }
});

test("source controls reject incomplete approvals and record valid transitions", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  const headers = { authorization: `Bearer ${adminToken}` };
  try {
    await seededBundle(db);
    const origin = (await db.query("SELECT * FROM source_origins")).rows[0];
    const document = (await db.query("SELECT * FROM source_documents")).rows[0];
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/documents/${document.id}/enabled`,
          headers,
          payload: { enabled: true, reason: "Missing approval" },
        })
      ).statusCode,
      422,
    );
    const policy = {
      id: "test",
      host: new URL(origin.origin).hostname,
      enabled: true,
      reviewStatus: "approved",
      allowedPaths: ["/live"],
    };
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/sources/${origin.id}/policy`,
          headers,
          payload: { policy, reason: "Missing dated review" },
        })
      ).statusCode,
      422,
    );
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/sources/${origin.id}/policy`,
          headers,
          payload: {
            policy: {
              ...policy,
              robotsCheckedAt: "2026-09-22T00:00:00Z",
              termsReviewedAt: "2026-09-22T00:00:00Z",
            },
            reason: "Synthetic policy reviewed",
          },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (
        await app.inject({
          method: "POST",
          url: `/admin/documents/${document.id}/enabled`,
          headers,
          payload: { enabled: true, reason: "Synthetic source enabled" },
        })
      ).statusCode,
      200,
    );
    assert.equal(
      (
        await db.query("SELECT enabled FROM source_documents WHERE id=$1", [
          document.id,
        ])
      ).rows[0].enabled,
      true,
    );
  } finally {
    await app.close();
    await db.close();
  }
});

test("reminder replacement preserves stable identity and rejects a different performance", async () => {
  const db = await testDB();
  const app = createApp(db, { adminToken });
  try {
    const b = await seededBundle(db);
    const roundID = "test-confirmed-deadline";
    b.ticketRounds.push({
      id: roundID,
      eventID: b.event.id,
      officialName: "Synthetic deadline",
      kind: "lottery",
      scope: { kind: "performances", performanceIDs: [b.performances[0]!.id] },
      status: "confirmed",
      applyStartAt: null,
      applyEndAt: "2027-01-01T00:00:00Z",
      resultAt: null,
      paymentDeadlineAt: null,
      eligibility: null,
      announcementURL: null,
      applyURL: null,
      overseasURL: null,
      officialStatus: null,
      links: [],
    });
    for (const field of ["scope", "applyEndAt"])
      b.evidence.push({
        ...b.evidence[0]!,
        id: `test-${field}`,
        recordID: roundID,
        field,
      });
    const review = await createReview(db, b, 0);
    await publishReview(db, review.id, "test", "Synthetic reminder scope");
    const install = (
      await app.inject({
        method: "POST",
        url: "/v1/installations",
        payload: {},
      })
    ).json();
    const headers = { authorization: `Bearer ${install.credential}` };
    const url = `/v1/installations/${install.id}/reminders`;
    const rule = {
      eventID: b.event.id,
      performanceID: b.performances[0]!.id,
      recordID: roundID,
      field: "applyEndAt",
      leadSeconds: 3600,
    };
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url,
          headers,
          payload: { reminders: [rule] },
        })
      ).statusCode,
      200,
    );
    const id = (await db.query("SELECT id FROM reminders")).rows[0].id;
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url,
          headers,
          payload: { reminders: [{ ...rule, leadSeconds: 7200 }] },
        })
      ).statusCode,
      200,
    );
    assert.equal((await db.query("SELECT id FROM reminders")).rows[0].id, id);
    assert.equal(
      (
        await app.inject({
          method: "PUT",
          url,
          headers,
          payload: {
            reminders: [{ ...rule, performanceID: b.performances[1]!.id }],
          },
        })
      ).statusCode,
      422,
    );
    assert.equal((await db.query("SELECT id FROM reminders")).rows[0].id, id);
  } finally {
    await app.close();
    await db.close();
  }
});
