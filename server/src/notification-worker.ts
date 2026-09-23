import { createHash, randomUUID } from "node:crypto";

import type { DB } from "./db.js";
import {
  reconcileReminder,
  type ApnsMessage,
  type ApnsSendResult,
  type LatestPublishedBundle,
  type NotificationContent,
  type ServerDeadlineReminder,
} from "./notifications/index.js";

export interface NotificationSender {
  send(message: ApnsMessage): Promise<ApnsSendResult>;
}

export type NotificationTransportProvider = (
  environment: "development" | "production",
) => NotificationSender;

export interface ScheduleNotificationsOptions {
  readonly maxOutboxEvents?: number;
  readonly now?: Date;
}

export interface DeliverNotificationsOptions {
  readonly maxDeliveries?: number;
  readonly maxDatabaseAttempts?: number;
  readonly leaseSeconds?: number;
  readonly databaseRetryBaseMs?: number;
  readonly now?: Date;
}

export interface ScheduleNotificationsResult {
  readonly processedOutboxEvents: number;
  readonly scheduledDeliveries: number;
  readonly cancelledDeliveries: number;
}

export interface ReconcileInstallationResult {
  readonly scheduledDeliveries: number;
  readonly cancelledDeliveries: number;
}

export interface DeliverNotificationsResult {
  readonly claimed: number;
  readonly delivered: number;
  readonly retried: number;
  readonly failed: number;
  readonly cancelled: number;
}

interface DeliveryRow {
  readonly id: string;
  readonly installation_id: string;
  readonly dedupe_key: string;
  readonly event_id: string;
  readonly revision: number;
  readonly payload: StoredDeliveryPayload;
  readonly send_at: Date | string;
  readonly expires_at: Date | string;
  readonly attempts: number;
  readonly lease_token: string;
}

interface StoredDeliveryPayload {
  readonly category: "change" | "deadline" | "withdrawn";
  readonly notification: NotificationContent;
  readonly collapseID: string;
  readonly reminderID?: string;
  readonly withdrawnEventID?: string;
  readonly replacementID?: string;
  readonly audience?: {
    readonly installationID: string;
    readonly performanceIDs: readonly string[];
    readonly changesEnabled: true;
  };
}

interface WithdrawnOutboxPayload {
  readonly eventID: string;
  readonly revision: number;
  readonly replacementID?: string;
  readonly officialTitle: string;
  readonly audience: readonly {
    readonly installationID: string;
    readonly performanceIDs: readonly string[];
    readonly changesEnabled: boolean;
  }[];
}

interface EventRow {
  readonly id: string;
  readonly revision: number;
  readonly bundle: LatestPublishedBundle & {
    readonly event: LatestPublishedBundle["event"] & {
      readonly officialTitle?: string;
    };
  };
  readonly deleted: boolean;
}

const DEFAULT_CHANGE_LIFETIME_MS = 7 * 24 * 60 * 60_000;

/**
 * Consumes committed publication outbox rows. Each row and all delivery
 * mutations commit atomically, so a crash before commit safely replays it.
 */
export async function scheduleNotifications(
  db: DB,
  options: ScheduleNotificationsOptions = {},
): Promise<ScheduleNotificationsResult> {
  const limit = positiveInteger(
    options.maxOutboxEvents ?? 100,
    "maxOutboxEvents",
  );
  const now = options.now ?? new Date();
  let processedOutboxEvents = 0;
  let scheduledDeliveries = 0;
  let cancelledDeliveries = 0;

  while (processedOutboxEvents < limit) {
    const outcome = await db.transaction(async (tx) => {
      const outbox = (
        await tx.query<{
          id: string;
          event_id: string;
          revision: number;
          kind: "event.changed" | "event.withdrawn";
          payload: unknown;
        }>(
          "SELECT id,event_id,revision,kind,payload FROM outbox_events WHERE processed_at IS NULL AND kind IN('event.changed','event.withdrawn') ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1",
        )
      ).rows[0];
      if (!outbox) return null;

      const event = (
        await tx.query<EventRow>(
          "SELECT id,revision,bundle,deleted FROM events WHERE id=$1",
          [outbox.event_id],
        )
      ).rows[0];
      let scheduled = 0;
      let cancelled = 0;
      if (outbox.kind === "event.withdrawn") {
        cancelled += await cancelEventDeliveries(tx, outbox.event_id);
        scheduled += await scheduleWithdrawnDeliveries(
          tx,
          parseWithdrawnPayload(
            outbox.payload,
            outbox.event_id,
            Number(outbox.revision),
          ),
          now,
        );
      } else if (!event || event.deleted) {
        cancelled += await cancelEventDeliveries(tx, outbox.event_id);
      } else {
        scheduled += await scheduleChangeDeliveries(tx, event, now);
        const reminderResult = await reconcileEventReminders(tx, event, now);
        scheduled += reminderResult.scheduled;
        cancelled += reminderResult.cancelled;
      }

      await tx.query("UPDATE outbox_events SET processed_at=$2 WHERE id=$1", [
        outbox.id,
        now,
      ]);
      return { scheduled, cancelled };
    });
    if (!outcome) break;
    processedOutboxEvents += 1;
    scheduledDeliveries += outcome.scheduled;
    cancelledDeliveries += outcome.cancelled;
  }

  return { processedOutboxEvents, scheduledDeliveries, cancelledDeliveries };
}

/**
 * Reconciles only deadline reminders for one installation. API mutations can
 * call this with their transaction DB; it never sends historical change
 * notifications and performs no network I/O.
 */
export async function reconcileInstallationNotifications(
  db: DB,
  installationID: string,
  options: { readonly now?: Date } = {},
): Promise<ReconcileInstallationResult> {
  const now = options.now ?? new Date();
  return await db.transaction(async (tx) => {
    let cancelledDeliveries =
      (
        await tx.query(
          `UPDATE notification_deliveries d
          SET status='cancelled',last_error='reminder_removed',lease_until=NULL,lease_token=NULL
        WHERE d.installation_id=$1 AND d.payload->>'category'='deadline'
          AND d.status IN('pending','retry','sending')
          AND NOT EXISTS (
            SELECT 1 FROM reminders r
             WHERE r.id::text=d.payload->>'reminderID' AND r.installation_id=$1
          )`,
          [installationID],
        )
      ).rowCount ?? 0;
    let scheduledDeliveries = 0;
    const eventIDs = (
      await tx.query<{ event_id: string }>(
        "SELECT DISTINCT event_id FROM reminders WHERE installation_id=$1",
        [installationID],
      )
    ).rows;
    for (const { event_id: eventID } of eventIDs) {
      const event = (
        await tx.query<EventRow>(
          "SELECT id,revision,bundle,deleted FROM events WHERE id=$1",
          [eventID],
        )
      ).rows[0];
      if (!event || event.deleted) {
        cancelledDeliveries +=
          (
            await tx.query(
              `UPDATE notification_deliveries
              SET status='cancelled',last_error='event_removed',lease_until=NULL,lease_token=NULL
            WHERE installation_id=$1 AND event_id=$2 AND payload->>'category'='deadline'
              AND status IN('pending','retry','sending')`,
              [installationID, eventID],
            )
          ).rowCount ?? 0;
        continue;
      }
      const result = await reconcileEventReminders(
        tx,
        event,
        now,
        installationID,
        true,
      );
      scheduledDeliveries += result.scheduled;
      cancelledDeliveries += result.cancelled;
    }
    return { scheduledDeliveries, cancelledDeliveries };
  });
}

/**
 * Claims deliveries with a fencing lease and performs a fresh authorization,
 * subscription, event revision, and expiry check before each APNs request.
 *
 * APNs and the database cannot share a transaction: an acknowledgement can be
 * lost before `delivered` commits. The stable APNs collapse ID limits duplicate
 * presentation, while this worker intentionally provides at-least-once delivery.
 */
export async function deliverNotifications(
  db: DB,
  transportProvider: NotificationTransportProvider,
  options: DeliverNotificationsOptions = {},
): Promise<DeliverNotificationsResult> {
  const limit = positiveInteger(options.maxDeliveries ?? 50, "maxDeliveries");
  const maxAttempts = positiveInteger(
    options.maxDatabaseAttempts ?? 5,
    "maxDatabaseAttempts",
  );
  const leaseSeconds = positiveInteger(
    options.leaseSeconds ?? 60,
    "leaseSeconds",
  );
  const databaseRetryBaseMs = positiveInteger(
    options.databaseRetryBaseMs ?? 5_000,
    "databaseRetryBaseMs",
  );
  const now = options.now ?? new Date();
  const counters = {
    claimed: 0,
    delivered: 0,
    retried: 0,
    failed: 0,
    cancelled: 0,
  };

  while (counters.claimed < limit) {
    const delivery = await claimDelivery(db, now, leaseSeconds, maxAttempts);
    if (!delivery) break;
    counters.claimed += 1;

    const preflight = await validateDelivery(db, delivery, now);
    if (!preflight.valid) {
      if (await finishDelivery(db, delivery, "cancelled", preflight.reason))
        counters.cancelled += 1;
      continue;
    }

    let result: ApnsSendResult;
    try {
      result = await transportProvider(preflight.environment).send({
        deviceToken: preflight.pushToken,
        notification: delivery.payload.notification,
        expiration: asDate(delivery.expires_at),
        collapseID: delivery.payload.collapseID,
      });
    } catch (error) {
      result = {
        outcome: "retry",
        reason:
          error instanceof Error ? error.message : "NotificationTransportError",
        attempts: 1,
        retryAfterMs: databaseRetryBaseMs,
      };
    }

    if (result.outcome === "sent") {
      if (await markDelivered(db, delivery, now)) counters.delivered += 1;
      continue;
    }
    if (result.outcome === "invalid_token") {
      if (
        await invalidateTokenAndFail(
          db,
          delivery,
          preflight.pushToken,
          result.reason,
        )
      )
        counters.failed += 1;
      continue;
    }
    if (result.outcome === "failed") {
      if (await finishDelivery(db, delivery, "failed", result.reason))
        counters.failed += 1;
      continue;
    }

    if (delivery.attempts >= maxAttempts) {
      if (
        await finishDelivery(
          db,
          delivery,
          "failed",
          `Retry limit: ${result.reason}`,
        )
      )
        counters.failed += 1;
    } else if (
      await retryDelivery(db, delivery, now, result.retryAfterMs, result.reason)
    ) {
      counters.retried += 1;
    }
  }

  return counters;
}

async function scheduleChangeDeliveries(
  db: DB,
  event: EventRow,
  now: Date,
): Promise<number> {
  const installations = (
    await db.query<{
      installation_id: string;
    }>(
      `SELECT s.installation_id
       FROM subscriptions s JOIN installations i ON i.id=s.installation_id
      WHERE s.event_id=$1 AND s.changes_enabled=true AND i.push_token IS NOT NULL`,
      [event.id],
    )
  ).rows;
  let scheduled = 0;
  for (const installation of installations) {
    const deliveryID = randomUUID();
    const dedupeKey = `change:${installation.installation_id}:${event.id}:${event.revision}`;
    const notification: NotificationContent = {
      title: event.bundle.event.officialTitle ?? "公演信息更新",
      body:
        event.bundle.event.status === "cancelled"
          ? "公演状态已更新为取消，请查看官方说明。"
          : "公演资料已更新，请核对最新官方信息。",
      deepLink: {
        notificationID: deliveryNotificationID(dedupeKey),
        eventID: event.id,
        tab: "overview",
        cardKey: "event-update",
        revision: event.revision,
      },
      sound: "default",
    };
    const inserted = await upsertCancelledDelivery(db, {
      id: deliveryID,
      installationID: installation.installation_id,
      dedupeKey,
      eventID: event.id,
      revision: event.revision,
      payload: {
        category: "change",
        notification,
        collapseID: collapseID(
          `change:${installation.installation_id}:${event.id}`,
        ),
      },
      sendAt: now,
      expiresAt: new Date(now.getTime() + DEFAULT_CHANGE_LIFETIME_MS),
    });
    scheduled += inserted;
  }
  return scheduled;
}

async function scheduleWithdrawnDeliveries(
  db: DB,
  payload: WithdrawnOutboxPayload,
  now: Date,
): Promise<number> {
  const optedAudience = new Map(
    payload.audience
      .filter((entry) => entry.changesEnabled)
      .map((entry) => [entry.installationID, entry] as const),
  );
  if (optedAudience.size === 0) return 0;

  const existing = (
    await db.query<{ id: string }>(
      "SELECT id FROM installations WHERE id=ANY($1::uuid[])",
      [[...optedAudience.keys()]],
    )
  ).rows;
  let scheduled = 0;
  for (const installation of existing) {
    const audience = optedAudience.get(installation.id);
    if (!audience) continue;
    const deliveryID = randomUUID();
    const dedupeKey = `withdrawn:${installation.id}:${payload.eventID}:${payload.revision}`;
    const notification: NotificationContent = {
      title: payload.officialTitle || "公演信息更新",
      body: payload.replacementID
        ? "此公演资料已确认撤回或合并，请查看替代公演与更新说明。"
        : "此公演资料已确认撤回，请查看更新说明。",
      deepLink: {
        notificationID: deliveryNotificationID(dedupeKey),
        eventID: payload.replacementID ?? payload.eventID,
        tab: "overview",
        cardKey: payload.replacementID
          ? "event-replacement"
          : "event-withdrawn",
        revision: payload.revision,
      },
      sound: "default",
    };
    scheduled += await upsertCancelledDelivery(db, {
      id: deliveryID,
      installationID: installation.id,
      dedupeKey,
      eventID: payload.eventID,
      revision: payload.revision,
      payload: {
        category: "withdrawn",
        notification,
        collapseID: collapseID(
          `withdrawn:${installation.id}:${payload.eventID}`,
        ),
        withdrawnEventID: payload.eventID,
        ...(payload.replacementID
          ? { replacementID: payload.replacementID }
          : {}),
        audience: {
          installationID: installation.id,
          performanceIDs: [...new Set(audience.performanceIDs)].sort(),
          changesEnabled: true,
        },
      },
      sendAt: now,
      expiresAt: new Date(now.getTime() + DEFAULT_CHANGE_LIFETIME_MS),
    });
  }
  return scheduled;
}

async function reconcileEventReminders(
  db: DB,
  event: EventRow,
  now: Date,
  installationID?: string,
  reactivateFailed = false,
): Promise<{ scheduled: number; cancelled: number }> {
  const rows = (
    await db.query<{
      id: string;
      installation_id: string;
      event_id: string;
      performance_id: string;
      record_id: string;
      field: "applyEndAt" | "paymentDeadlineAt";
      lead_seconds: number;
      enabled: boolean;
      performance_ids: string[] | null;
      changes_enabled: boolean | null;
      push_token: string | null;
    }>(
      `SELECT r.*,s.performance_ids,s.changes_enabled,i.push_token
       FROM reminders r
       JOIN installations i ON i.id=r.installation_id
       LEFT JOIN subscriptions s ON s.installation_id=r.installation_id AND s.event_id=r.event_id
      WHERE r.event_id=$1${installationID ? " AND r.installation_id=$2" : ""}`,
      installationID ? [event.id, installationID] : [event.id],
    )
  ).rows;
  let scheduled = 0;
  let cancelled = 0;
  for (const row of rows) {
    const plan = reconcileReminder({
      bundle: event.bundle,
      reminder: toReminder(row),
      subscription:
        row.performance_ids === null
          ? null
          : {
              eventID: row.event_id,
              enabled: true,
              performanceIDs: row.performance_ids,
            },
      now,
    });
    if (plan.action === "cancel" || row.push_token === null) {
      cancelled += await cancelReminderDeliveries(
        db,
        row.id,
        plan.action === "cancel" ? plan.reason : "missing_push_token",
      );
      continue;
    }

    // A deadline or effective-scope change supersedes any other pending key.
    cancelled +=
      (
        await db.query(
          `UPDATE notification_deliveries
          SET status='cancelled',last_error='superseded_deadline',lease_until=NULL,lease_token=NULL
        WHERE installation_id=$1 AND payload->>'reminderID'=$2
          AND dedupe_key<>$3 AND status IN('pending','retry','sending')`,
          [row.installation_id, row.id, plan.deliveryKey],
        )
      ).rowCount ?? 0;

    const deliveryID = randomUUID();
    const performance = event.bundle.performances.find(
      (candidate) => candidate.id === row.performance_id,
    );
    const notification: NotificationContent = {
      title: event.bundle.event.officialTitle ?? "公演截止提醒",
      body:
        row.field === "paymentDeadlineAt"
          ? "付款期限临近，请核对官方信息。"
          : "申请期限临近，请核对官方信息。",
      deepLink: {
        notificationID: deliveryNotificationID(plan.deliveryKey),
        eventID: event.id,
        ...(performance?.editionID ? { editionID: performance.editionID } : {}),
        ...(performance?.stopID ? { stopID: performance.stopID } : {}),
        performanceID: row.performance_id,
        tab: "tickets",
        cardKey: `ticket-round:${row.record_id}`,
        revision: event.revision,
      },
      sound: "default",
    };
    scheduled += await upsertCancelledDelivery(
      db,
      {
        id: deliveryID,
        installationID: row.installation_id,
        dedupeKey: plan.deliveryKey,
        eventID: event.id,
        revision: event.revision,
        payload: {
          category: "deadline",
          reminderID: row.id,
          notification,
          collapseID: collapseID(`reminder:${row.id}`),
        },
        sendAt: new Date(plan.scheduledAt),
        expiresAt: new Date(plan.deadlineAt),
      },
      reactivateFailed,
    );
  }
  return { scheduled, cancelled };
}

function toReminder(row: {
  readonly id: string;
  readonly installation_id: string;
  readonly event_id: string;
  readonly performance_id: string;
  readonly record_id: string;
  readonly field: "applyEndAt" | "paymentDeadlineAt";
  readonly lead_seconds: number;
  readonly enabled: boolean;
}): ServerDeadlineReminder {
  return {
    id: row.id,
    installationID: row.installation_id,
    eventID: row.event_id,
    entityID: row.record_id,
    performanceID: row.performance_id,
    deadlineField: row.field,
    offsetSeconds: Number(row.lead_seconds),
    enabled: row.enabled,
    deliveryMode: "server",
    triggerType: "deadline",
  };
}

async function upsertCancelledDelivery(
  db: DB,
  input: {
    readonly id: string;
    readonly installationID: string;
    readonly dedupeKey: string;
    readonly eventID: string;
    readonly revision: number;
    readonly payload: StoredDeliveryPayload;
    readonly sendAt: Date;
    readonly expiresAt: Date;
  },
  reactivateFailed = false,
): Promise<number> {
  const result = await db.query(
    `INSERT INTO notification_deliveries
       (id,installation_id,dedupe_key,event_id,revision,payload,send_at,expires_at)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8)
     ON CONFLICT(dedupe_key) DO UPDATE SET
       revision=EXCLUDED.revision,payload=EXCLUDED.payload,send_at=EXCLUDED.send_at,
       expires_at=EXCLUDED.expires_at,status='pending',attempts=0,last_error=NULL,
       lease_until=NULL,lease_token=NULL,delivered_at=NULL
     WHERE notification_deliveries.status='cancelled'
        OR ($9::boolean AND notification_deliveries.status='failed')
     RETURNING id`,
    [
      input.id,
      input.installationID,
      input.dedupeKey,
      input.eventID,
      input.revision,
      JSON.stringify(input.payload),
      input.sendAt,
      input.expiresAt,
      reactivateFailed,
    ],
  );
  return result.rows.length;
}

async function cancelEventDeliveries(db: DB, eventID: string): Promise<number> {
  return (
    (
      await db.query(
        "UPDATE notification_deliveries SET status='cancelled',last_error='event_removed',lease_until=NULL,lease_token=NULL WHERE event_id=$1 AND status IN('pending','retry','sending')",
        [eventID],
      )
    ).rowCount ?? 0
  );
}

async function cancelReminderDeliveries(
  db: DB,
  reminderID: string,
  reason: string,
): Promise<number> {
  return (
    (
      await db.query(
        "UPDATE notification_deliveries SET status='cancelled',last_error=$2,lease_until=NULL,lease_token=NULL WHERE payload->>'reminderID'=$1 AND status IN('pending','retry','sending')",
        [reminderID, reason],
      )
    ).rowCount ?? 0
  );
}

async function claimDelivery(
  db: DB,
  now: Date,
  leaseSeconds: number,
  maxAttempts: number,
): Promise<DeliveryRow | null> {
  return await db.transaction(async (tx) => {
    await tx.query(
      "UPDATE notification_deliveries SET status='expired',last_error='expired_before_send',lease_until=NULL,lease_token=NULL WHERE status IN('pending','retry','sending') AND expires_at<=$1",
      [now],
    );
    await tx.query(
      "UPDATE notification_deliveries SET status='failed',last_error='database_retry_limit',lease_until=NULL,lease_token=NULL WHERE status IN('pending','retry','sending') AND attempts>=$1",
      [maxAttempts],
    );
    const row = (
      await tx.query<DeliveryRow>(
        `SELECT * FROM notification_deliveries
        WHERE attempts<$2 AND send_at<=$1 AND expires_at>$1
          AND (status IN('pending','retry') OR (status='sending' AND lease_until<$1))
        ORDER BY send_at,id FOR UPDATE SKIP LOCKED LIMIT 1`,
        [now, maxAttempts],
      )
    ).rows[0];
    if (!row) return null;
    const leaseToken = randomUUID();
    const claimed = (
      await tx.query<DeliveryRow>(
        `UPDATE notification_deliveries
          SET status='sending',attempts=attempts+1,lease_token=$2,
              lease_until=$3
        WHERE id=$1 RETURNING *`,
        [row.id, leaseToken, new Date(now.getTime() + leaseSeconds * 1_000)],
      )
    ).rows[0];
    return claimed ?? null;
  });
}

type ValidDelivery =
  | { readonly valid: false; readonly reason: string }
  | {
      readonly valid: true;
      readonly pushToken: string;
      readonly environment: "development" | "production";
    };

async function validateDelivery(
  db: DB,
  delivery: DeliveryRow,
  now: Date,
): Promise<ValidDelivery> {
  if (asDate(delivery.expires_at).getTime() <= now.getTime())
    return { valid: false, reason: "expired_before_send" };
  const installation = (
    await db.query<{
      push_token: string | null;
      environment: "sandbox" | "production";
    }>("SELECT push_token,environment FROM installations WHERE id=$1", [
      delivery.installation_id,
    ])
  ).rows[0];
  if (!installation?.push_token)
    return { valid: false, reason: "installation_or_token_removed" };
  const event = (
    await db.query<EventRow>(
      "SELECT id,revision,bundle,deleted FROM events WHERE id=$1",
      [delivery.event_id],
    )
  ).rows[0];
  if (delivery.payload.category === "withdrawn") {
    if (!event || !event.deleted)
      return { valid: false, reason: "withdrawal_not_current" };
    if (event.revision !== Number(delivery.revision))
      return { valid: false, reason: "superseded_revision" };
    if (
      delivery.payload.withdrawnEventID !== delivery.event_id ||
      delivery.payload.audience?.installationID !== delivery.installation_id ||
      delivery.payload.audience.changesEnabled !== true
    ) {
      return { valid: false, reason: "invalid_withdrawal_audience" };
    }
    return {
      valid: true,
      pushToken: installation.push_token,
      environment:
        installation.environment === "production"
          ? "production"
          : "development",
    };
  }
  if (!event || event.deleted) return { valid: false, reason: "event_removed" };

  const subscription = (
    await db.query<{
      performance_ids: string[];
      changes_enabled: boolean;
    }>(
      "SELECT performance_ids,changes_enabled FROM subscriptions WHERE installation_id=$1 AND event_id=$2",
      [delivery.installation_id, delivery.event_id],
    )
  ).rows[0];
  if (!subscription) return { valid: false, reason: "subscription_removed" };

  if (delivery.payload.category === "change") {
    if (!subscription.changes_enabled)
      return { valid: false, reason: "change_notifications_disabled" };
    if (event.revision !== Number(delivery.revision))
      return { valid: false, reason: "superseded_revision" };
  } else {
    const reminderID = delivery.payload.reminderID;
    if (!reminderID)
      return { valid: false, reason: "invalid_reminder_payload" };
    const row = (
      await db.query<{
        id: string;
        installation_id: string;
        event_id: string;
        performance_id: string;
        record_id: string;
        field: "applyEndAt" | "paymentDeadlineAt";
        lead_seconds: number;
        enabled: boolean;
      }>("SELECT * FROM reminders WHERE id=$1", [reminderID])
    ).rows[0];
    if (!row) return { valid: false, reason: "reminder_removed" };
    const plan = reconcileReminder({
      bundle: event.bundle,
      reminder: toReminder(row),
      subscription: {
        eventID: delivery.event_id,
        enabled: true,
        performanceIDs: subscription.performance_ids,
      },
      now,
    });
    if (plan.action !== "schedule")
      return { valid: false, reason: plan.reason };
    if (plan.deliveryKey !== delivery.dedupe_key)
      return { valid: false, reason: "superseded_deadline" };
    if (event.revision !== Number(delivery.revision))
      return { valid: false, reason: "superseded_revision" };
  }

  return {
    valid: true,
    pushToken: installation.push_token,
    environment:
      installation.environment === "production" ? "production" : "development",
  };
}

async function markDelivered(
  db: DB,
  delivery: DeliveryRow,
  now: Date,
): Promise<boolean> {
  return (
    (
      await db.query(
        "UPDATE notification_deliveries SET status='delivered',delivered_at=$3,lease_until=NULL,lease_token=NULL,last_error=NULL WHERE id=$1 AND lease_token=$2 AND status='sending' RETURNING id",
        [delivery.id, delivery.lease_token, now],
      )
    ).rows.length === 1
  );
}

async function finishDelivery(
  db: DB,
  delivery: DeliveryRow,
  status: "cancelled" | "failed",
  reason: string,
): Promise<boolean> {
  return (
    (
      await db.query(
        "UPDATE notification_deliveries SET status=$3,last_error=$4,lease_until=NULL,lease_token=NULL WHERE id=$1 AND lease_token=$2 AND status='sending' RETURNING id",
        [delivery.id, delivery.lease_token, status, reason.slice(0, 2_000)],
      )
    ).rows.length === 1
  );
}

async function retryDelivery(
  db: DB,
  delivery: DeliveryRow,
  now: Date,
  retryAfterMs: number,
  reason: string,
): Promise<boolean> {
  const boundedDelay = Math.max(0, Math.min(retryAfterMs, 60 * 60_000));
  return (
    (
      await db.query(
        "UPDATE notification_deliveries SET status='retry',send_at=$3,last_error=$4,lease_until=NULL,lease_token=NULL WHERE id=$1 AND lease_token=$2 AND status='sending' RETURNING id",
        [
          delivery.id,
          delivery.lease_token,
          new Date(now.getTime() + boundedDelay),
          reason.slice(0, 2_000),
        ],
      )
    ).rows.length === 1
  );
}

async function invalidateTokenAndFail(
  db: DB,
  delivery: DeliveryRow,
  attemptedToken: string,
  reason: string,
): Promise<boolean> {
  return await db.transaction(async (tx) => {
    const invalidated =
      (
        await tx.query(
          "UPDATE installations SET push_token=NULL WHERE id=$1 AND push_token=$2 RETURNING id",
          [delivery.installation_id, attemptedToken],
        )
      ).rows.length === 1;
    if (invalidated) {
      await tx.query(
        "UPDATE notification_deliveries SET status='cancelled',last_error='invalid_device_token',lease_until=NULL,lease_token=NULL WHERE installation_id=$1 AND id<>$2 AND status IN('pending','retry','sending')",
        [delivery.installation_id, delivery.id],
      );
    }
    return (
      (
        await tx.query(
          "UPDATE notification_deliveries SET status='failed',last_error=$3,lease_until=NULL,lease_token=NULL WHERE id=$1 AND lease_token=$2 AND status='sending' RETURNING id",
          [delivery.id, delivery.lease_token, reason.slice(0, 2_000)],
        )
      ).rows.length === 1
    );
  });
}

function collapseID(dedupeKey: string): string {
  return createHash("sha256").update(dedupeKey).digest("hex");
}

function deliveryNotificationID(dedupeKey: string): string {
  return `notification:${createHash("sha256").update(dedupeKey).digest("hex")}`;
}

function parseWithdrawnPayload(
  value: unknown,
  eventID: string,
  revision: number,
): WithdrawnOutboxPayload {
  if (!value || typeof value !== "object")
    throw new Error("Invalid event.withdrawn outbox payload");
  const raw = value as Record<string, unknown>;
  if (
    raw.eventID !== eventID ||
    Number(raw.revision) !== revision ||
    typeof raw.officialTitle !== "string"
  ) {
    throw new Error("event.withdrawn payload does not match its outbox row");
  }
  if (
    raw.replacementID !== undefined &&
    typeof raw.replacementID !== "string"
  ) {
    throw new Error("Invalid event.withdrawn replacementID");
  }
  if (!Array.isArray(raw.audience))
    throw new Error("Invalid event.withdrawn audience");
  const audience = raw.audience.map((entry) => {
    if (!entry || typeof entry !== "object")
      throw new Error("Invalid event.withdrawn audience entry");
    const candidate = entry as Record<string, unknown>;
    if (
      typeof candidate.installationID !== "string" ||
      !Array.isArray(candidate.performanceIDs) ||
      candidate.performanceIDs.some((id) => typeof id !== "string") ||
      typeof candidate.changesEnabled !== "boolean"
    ) {
      throw new Error("Invalid event.withdrawn audience entry");
    }
    return {
      installationID: candidate.installationID,
      performanceIDs: candidate.performanceIDs as string[],
      changesEnabled: candidate.changesEnabled,
    };
  });
  return {
    eventID,
    revision,
    ...(typeof raw.replacementID === "string"
      ? { replacementID: raw.replacementID }
      : {}),
    officialTitle: raw.officialTitle,
    audience,
  };
}

function asDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value);
}

function positiveInteger(value: number, name: string): number {
  if (!Number.isSafeInteger(value) || value < 1)
    throw new RangeError(`${name} must be a positive safe integer`);
  return value;
}
