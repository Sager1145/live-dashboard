import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

import {
  deliverNotifications,
  reconcileInstallationNotifications,
  scheduleNotifications,
  type NotificationSender,
} from "../src/notification-worker.js";
import type {
  ApnsMessage,
  ApnsSendResult,
} from "../src/notifications/index.js";
import { testDB } from "./support.js";

const now = new Date("2026-09-22T12:00:00.000Z");

async function seedNotificationState(db: Awaited<ReturnType<typeof testDB>>) {
  const eventID = "event-notifications";
  const performanceID = "performance-1";
  const roundID = "round-1";
  const installationID = randomUUID();
  const reminderID = randomUUID();
  const outboxID = randomUUID();
  const token = "a".repeat(64);
  const bundle = {
    schemaVersion: 1,
    revision: 1,
    publishedAt: "2026-09-22T11:00:00.000Z",
    event: {
      id: eventID,
      officialTitle: "Synthetic Live",
      status: "scheduled",
    },
    performances: [{ id: performanceID }],
    ticketRounds: [
      {
        id: roundID,
        applyEndAt: "2026-09-25T12:00:00.000Z",
        paymentDeadlineAt: "2026-09-28T12:00:00.000Z",
        status: "confirmed",
        scope: { kind: "performances", performanceIDs: [performanceID] },
      },
    ],
  };
  await db.query(
    "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,1,$2,'hash-1')",
    [eventID, JSON.stringify(bundle)],
  );
  await db.query(
    "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,1,'event.changed',$4)",
    [outboxID, `${eventID}:1`, eventID, "{}"],
  );
  await db.query(
    "INSERT INTO installations(id,credential_hash,push_token,environment) VALUES($1,'credential',$2,'sandbox')",
    [installationID, token],
  );
  await db.query(
    "INSERT INTO subscriptions(installation_id,event_id,performance_ids) VALUES($1,$2,$3)",
    [installationID, eventID, JSON.stringify([performanceID])],
  );
  await db.query(
    "INSERT INTO reminders(id,installation_id,event_id,performance_id,record_id,field,lead_seconds) VALUES($1,$2,$3,$4,$5,'applyEndAt',259200)",
    [reminderID, installationID, eventID, performanceID, roundID],
  );
  return {
    eventID,
    performanceID,
    roundID,
    installationID,
    reminderID,
    token,
    bundle,
  };
}

async function seedWithdrawal(
  db: Awaited<ReturnType<typeof testDB>>,
  replacementID?: string,
) {
  const fixture = await seedNotificationState(db);
  const optedOutInstallationID = randomUUID();
  await db.query("UPDATE outbox_events SET processed_at=$2 WHERE event_id=$1", [
    fixture.eventID,
    now,
  ]);
  await db.query("UPDATE events SET revision=2,deleted=true WHERE id=$1", [
    fixture.eventID,
  ]);
  await db.query("DELETE FROM subscriptions WHERE event_id=$1", [
    fixture.eventID,
  ]);
  await db.query("DELETE FROM reminders WHERE event_id=$1", [fixture.eventID]);
  await db.query(
    "INSERT INTO installations(id,credential_hash,push_token,environment) VALUES($1,'credential',$2,'production')",
    [optedOutInstallationID, "c".repeat(64)],
  );
  const payload = {
    eventID: fixture.eventID,
    revision: 2,
    ...(replacementID ? { replacementID } : {}),
    officialTitle: "Synthetic Live",
    audience: [
      {
        installationID: fixture.installationID,
        performanceIDs: [fixture.performanceID],
        changesEnabled: true,
      },
      {
        installationID: optedOutInstallationID,
        performanceIDs: [fixture.performanceID],
        changesEnabled: false,
      },
    ],
  };
  await db.query(
    "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,2,'event.withdrawn',$4)",
    [
      randomUUID(),
      `withdrawn:${fixture.eventID}:2`,
      fixture.eventID,
      JSON.stringify(payload),
    ],
  );
  return { ...fixture, optedOutInstallationID, replacementID };
}

test("scheduler consumes outbox atomically and is idempotent", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    assert.deepEqual(await scheduleNotifications(db, { now }), {
      processedOutboxEvents: 1,
      scheduledDeliveries: 2,
      cancelledDeliveries: 0,
    });
    assert.equal(
      (await db.query("SELECT count(*) AS n FROM notification_deliveries"))
        .rows[0]!.n,
      2,
    );
    assert.ok(
      (await db.query("SELECT processed_at FROM outbox_events")).rows[0]!
        .processed_at,
    );
    assert.deepEqual(await scheduleNotifications(db, { now }), {
      processedOutboxEvents: 0,
      scheduledDeliveries: 0,
      cancelledDeliveries: 0,
    });

    const deadline = (
      await db.query(
        "SELECT * FROM notification_deliveries WHERE payload->>'category'='deadline'",
      )
    ).rows[0]!;
    assert.equal(deadline.payload.reminderID, fixture.reminderID);
    assert.equal(
      deadline.payload.notification.deepLink.performanceID,
      fixture.performanceID,
    );
  } finally {
    await db.close();
  }
});

test("withdrawal outbox uses the captured audience and does not call removal cancellation", async () => {
  const db = await testDB();
  try {
    const fixture = await seedWithdrawal(db);
    assert.deepEqual(await scheduleNotifications(db, { now }), {
      processedOutboxEvents: 1,
      scheduledDeliveries: 1,
      cancelledDeliveries: 0,
    });
    const rows = (await db.query("SELECT * FROM notification_deliveries")).rows;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]!.installation_id, fixture.installationID);
    assert.equal(rows[0]!.payload.category, "withdrawn");
    assert.equal(rows[0]!.payload.audience.changesEnabled, true);
    assert.equal(
      rows[0]!.payload.notification.deepLink.eventID,
      fixture.eventID,
    );
    assert.equal(
      rows[0]!.payload.notification.deepLink.cardKey,
      "event-withdrawn",
    );
    assert.match(rows[0]!.payload.notification.body, /撤回/);
    assert.doesNotMatch(rows[0]!.payload.notification.body, /取消/);
    assert.equal(
      (await scheduleNotifications(db, { now })).processedOutboxEvents,
      0,
    );
  } finally {
    await db.close();
  }
});

test("withdrawal with a replacement deep-links to the replacement", async () => {
  const db = await testDB();
  try {
    const replacementID = "replacement-event";
    await seedWithdrawal(db, replacementID);
    await scheduleNotifications(db, { now });
    const payload = (
      await db.query("SELECT payload FROM notification_deliveries")
    ).rows[0]!.payload;
    assert.equal(payload.withdrawnEventID, "event-notifications");
    assert.equal(payload.replacementID, replacementID);
    assert.equal(payload.notification.deepLink.eventID, replacementID);
    assert.equal(payload.notification.deepLink.cardKey, "event-replacement");
  } finally {
    await db.close();
  }
});

test("unrelated publication reactivates the same deadline delivery key", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    const original = (
      await db.query(
        "SELECT id,dedupe_key FROM notification_deliveries WHERE payload->>'category'='deadline'",
      )
    ).rows[0]!;
    const revision2 = structuredClone(fixture.bundle);
    revision2.revision = 2;
    revision2.event.officialTitle = "Synthetic Live corrected title";
    await db.query("UPDATE events SET revision=2,bundle=$2 WHERE id=$1", [
      fixture.eventID,
      JSON.stringify(revision2),
    ]);
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE event_id=$1 AND status IN('pending','retry')",
      [fixture.eventID],
    );
    await db.query(
      "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,2,'event.changed',$4)",
      [randomUUID(), `${fixture.eventID}:2`, fixture.eventID, "{}"],
    );
    await scheduleNotifications(db, { now });
    const current = (
      await db.query(
        "SELECT id,dedupe_key,status,revision FROM notification_deliveries WHERE payload->>'category'='deadline'",
      )
    ).rows;
    assert.equal(current.length, 1);
    assert.equal(current[0]!.id, original.id);
    assert.equal(current[0]!.dedupe_key, original.dedupe_key);
    assert.equal(current[0]!.status, "pending");
    assert.equal(current[0]!.revision, 2);
  } finally {
    await db.close();
  }
});

test("installation reconciliation schedules new reminders without replaying change history", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    // Simulate an already consumed publication from before this installation registered.
    await db.query(
      "UPDATE outbox_events SET processed_at=$2 WHERE event_id=$1",
      [fixture.eventID, now],
    );
    assert.deepEqual(
      await reconcileInstallationNotifications(db, fixture.installationID, {
        now,
      }),
      {
        scheduledDeliveries: 1,
        cancelledDeliveries: 0,
      },
    );
    const rows = (await db.query("SELECT payload FROM notification_deliveries"))
      .rows;
    assert.equal(rows.length, 1);
    assert.equal(rows[0]!.payload.category, "deadline");

    await db.query("DELETE FROM reminders WHERE id=$1", [fixture.reminderID]);
    assert.deepEqual(
      await reconcileInstallationNotifications(db, fixture.installationID, {
        now,
      }),
      {
        scheduledDeliveries: 0,
        cancelledDeliveries: 1,
      },
    );
    assert.equal(
      (await db.query("SELECT status FROM notification_deliveries")).rows[0]!
        .status,
      "cancelled",
    );
  } finally {
    await db.close();
  }
});

test("installation reconciliation reactivates a valid deadline after token replacement", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    await db.query(
      "UPDATE notification_deliveries SET status='failed',last_error='Unregistered' WHERE payload->>'category'='deadline'",
    );
    await db.query("UPDATE installations SET push_token=$2 WHERE id=$1", [
      fixture.installationID,
      "b".repeat(64),
    ]);
    assert.deepEqual(
      await reconcileInstallationNotifications(db, fixture.installationID, {
        now,
      }),
      {
        scheduledDeliveries: 1,
        cancelledDeliveries: 0,
      },
    );
    const row = (
      await db.query(
        "SELECT status,attempts,last_error FROM notification_deliveries WHERE payload->>'category'='deadline'",
      )
    ).rows[0]!;
    assert.equal(row.status, "pending");
    assert.equal(row.attempts, 0);
    assert.equal(row.last_error, null);
  } finally {
    await db.close();
  }
});

test("changed deadline supersedes the old delivery and removed subscription cancels it", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    const revision2 = structuredClone(fixture.bundle);
    revision2.revision = 2;
    revision2.ticketRounds[0]!.applyEndAt = "2026-09-26T12:00:00.000Z";
    await db.query("UPDATE events SET revision=2,bundle=$2 WHERE id=$1", [
      fixture.eventID,
      JSON.stringify(revision2),
    ]);
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE event_id=$1 AND status IN('pending','retry')",
      [fixture.eventID],
    );
    await db.query(
      "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,2,'event.changed',$4)",
      [randomUUID(), `${fixture.eventID}:2`, fixture.eventID, "{}"],
    );
    await scheduleNotifications(db, { now });
    const deadlines = (
      await db.query(
        "SELECT status FROM notification_deliveries WHERE payload->>'category'='deadline' ORDER BY send_at",
      )
    ).rows;
    assert.deepEqual(
      deadlines.map((row) => row.status),
      ["cancelled", "pending"],
    );

    await db.query("DELETE FROM subscriptions WHERE installation_id=$1", [
      fixture.installationID,
    ]);
    const revision3 = structuredClone(revision2);
    revision3.revision = 3;
    await db.query("UPDATE events SET revision=3,bundle=$2 WHERE id=$1", [
      fixture.eventID,
      JSON.stringify(revision3),
    ]);
    await db.query(
      "INSERT INTO outbox_events(id,dedupe_key,event_id,revision,kind,payload) VALUES($1,$2,$3,3,'event.changed',$4)",
      [randomUUID(), `${fixture.eventID}:3`, fixture.eventID, "{}"],
    );
    await scheduleNotifications(db, { now });
    assert.equal(
      (
        await db.query(
          "SELECT count(*) AS n FROM notification_deliveries WHERE payload->>'category'='deadline' AND status='pending'",
        )
      ).rows[0]!.n,
      0,
    );
  } finally {
    await db.close();
  }
});

class StubSender implements NotificationSender {
  readonly messages: ApnsMessage[] = [];
  constructor(
    readonly result: ApnsSendResult,
    readonly beforeReturn?: () => Promise<void>,
  ) {}
  async send(message: ApnsMessage): Promise<ApnsSendResult> {
    this.messages.push(message);
    await this.beforeReturn?.();
    return this.result;
  }
}

test("withdrawal delivery permits the deleted matching revision without a live subscription", async () => {
  const db = await testDB();
  try {
    const fixture = await seedWithdrawal(db);
    await scheduleNotifications(db, { now });
    const sender = new StubSender({ outcome: "sent", attempts: 1 });
    const result = await deliverNotifications(
      db,
      (environment) => {
        assert.equal(environment, "development");
        return sender;
      },
      { now, maxDeliveries: 1 },
    );
    assert.equal(result.delivered, 1);
    assert.equal(sender.messages[0]!.deviceToken, fixture.token);
  } finally {
    await db.close();
  }
});

test("withdrawal delivery cancels when the deleted event revision no longer matches", async () => {
  const db = await testDB();
  try {
    const fixture = await seedWithdrawal(db);
    await scheduleNotifications(db, { now });
    await db.query("UPDATE events SET revision=3 WHERE id=$1", [
      fixture.eventID,
    ]);
    const sender = new StubSender({ outcome: "sent", attempts: 1 });
    const result = await deliverNotifications(db, () => sender, {
      now,
      maxDeliveries: 1,
    });
    assert.equal(result.cancelled, 1);
    assert.equal(sender.messages.length, 0);
  } finally {
    await db.close();
  }
});

test("delivery leases work once and records successful APNs delivery", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE payload->>'category'='change'",
    );
    const sender = new StubSender({
      outcome: "sent",
      attempts: 1,
      apnsID: "apns-id",
    });
    assert.deepEqual(
      await deliverNotifications(
        db,
        (environment) => {
          assert.equal(environment, "development");
          return sender;
        },
        { now, maxDeliveries: 1 },
      ),
      {
        claimed: 1,
        delivered: 1,
        retried: 0,
        failed: 0,
        cancelled: 0,
      },
    );
    assert.equal(sender.messages[0]!.deviceToken, fixture.token);
    assert.equal(sender.messages[0]!.collapseID.length, 64);
    assert.equal(
      (
        await db.query(
          "SELECT status FROM notification_deliveries WHERE payload->>'category'='deadline'",
        )
      ).rows[0]!.status,
      "delivered",
    );
    assert.equal(
      (await deliverNotifications(db, () => sender, { now })).claimed,
      0,
    );
  } finally {
    await db.close();
  }
});

test("latest revision and subscription are checked again before send", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE payload->>'category'='change'",
    );
    const newer = structuredClone(fixture.bundle);
    newer.revision = 2;
    newer.ticketRounds[0]!.applyEndAt = "2026-09-26T12:00:00.000Z";
    await db.query("UPDATE events SET revision=2,bundle=$2 WHERE id=$1", [
      fixture.eventID,
      JSON.stringify(newer),
    ]);
    const sender = new StubSender({ outcome: "sent", attempts: 1 });
    const result = await deliverNotifications(db, () => sender, {
      now,
      maxDeliveries: 1,
    });
    assert.equal(result.cancelled, 1);
    assert.equal(sender.messages.length, 0);
    assert.equal(
      (
        await db.query(
          "SELECT status FROM notification_deliveries WHERE payload->>'category'='deadline'",
        )
      ).rows[0]!.status,
      "cancelled",
    );
  } finally {
    await db.close();
  }
});

test("invalid-token cleanup cannot erase a token rotated during the request", async () => {
  const db = await testDB();
  try {
    const fixture = await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE payload->>'category'='change'",
    );
    const rotated = "b".repeat(64);
    const sender = new StubSender(
      { outcome: "invalid_token", reason: "Unregistered", attempts: 1 },
      async () => {
        await db.query("UPDATE installations SET push_token=$2 WHERE id=$1", [
          fixture.installationID,
          rotated,
        ]);
      },
    );
    const result = await deliverNotifications(db, () => sender, {
      now,
      maxDeliveries: 1,
    });
    assert.equal(result.failed, 1);
    assert.equal(
      (
        await db.query("SELECT push_token FROM installations WHERE id=$1", [
          fixture.installationID,
        ])
      ).rows[0]!.push_token,
      rotated,
    );
  } finally {
    await db.close();
  }
});

test("transport failures enter bounded database retry and never count as success", async () => {
  const db = await testDB();
  try {
    await seedNotificationState(db);
    await scheduleNotifications(db, { now });
    await db.query(
      "UPDATE notification_deliveries SET status='cancelled' WHERE payload->>'category'='change'",
    );
    const retrying = new StubSender({
      outcome: "retry",
      reason: "TooManyRequests",
      attempts: 3,
      retryAfterMs: 2_000,
    });
    const first = await deliverNotifications(db, () => retrying, {
      now,
      maxDeliveries: 1,
      maxDatabaseAttempts: 2,
    });
    assert.equal(first.retried, 1);
    const row = (
      await db.query(
        "SELECT status,attempts,send_at FROM notification_deliveries WHERE payload->>'category'='deadline'",
      )
    ).rows[0]!;
    assert.equal(row.status, "retry");
    assert.equal(row.attempts, 1);
    assert.equal(
      new Date(row.send_at).toISOString(),
      "2026-09-22T12:00:02.000Z",
    );

    const failed = new StubSender({
      outcome: "failed",
      reason: "MissingApnsPrivateKey",
      attempts: 0,
    });
    const second = await deliverNotifications(db, () => failed, {
      now: new Date("2026-09-22T12:00:02.000Z"),
      maxDeliveries: 1,
      maxDatabaseAttempts: 2,
    });
    assert.equal(second.failed, 1);
    assert.equal(second.delivered, 0);
  } finally {
    await db.close();
  }
});
