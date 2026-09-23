import { createHash } from "node:crypto";

import type {
  InstallationSubscription,
  LatestPublishedBundle,
  ReminderPlan,
  ServerDeadlineReminder,
} from "./types.js";

export interface ReconcileReminderInput {
  readonly bundle: LatestPublishedBundle;
  readonly reminder: ServerDeadlineReminder;
  readonly subscription: InstallationSubscription | null;
  readonly now: Date;
}

export function makeDeliveryKey(input: {
  readonly installationID: string;
  readonly reminderID: string;
  readonly deadlineRevision: string | number;
  readonly triggerType: string;
}): string {
  const canonical = [
    input.installationID,
    input.reminderID,
    input.deadlineRevision,
    input.triggerType,
  ]
    .map((part) => String(part))
    .map((part) => `${Buffer.byteLength(part, "utf8")}:${part}`)
    .join("|");
  return `notification-delivery:${createHash("sha256").update(canonical).digest("hex")}`;
}

export function makeDeadlineRevision(input: {
  readonly entityID: string;
  readonly deadlineField: string;
  readonly deadlineAt: string;
  readonly performanceIDs: readonly string[];
}): string {
  const canonical = JSON.stringify({
    entityID: input.entityID,
    deadlineField: input.deadlineField,
    deadlineAt: input.deadlineAt,
    performanceIDs: [...new Set(input.performanceIDs)].sort(),
  });
  return createHash("sha256").update(canonical).digest("hex");
}

/** Reconciles one persisted rule against the latest committed public bundle. */
export function reconcileReminder(input: ReconcileReminderInput): ReminderPlan {
  const { bundle, reminder, subscription, now } = input;
  const cancel = (
    reason: Extract<ReminderPlan, { action: "cancel" }>["reason"],
  ): ReminderPlan => ({
    action: "cancel",
    reminderID: reminder.id,
    reason,
  });

  if (!reminder.enabled) return cancel("reminder_disabled");
  if (reminder.deliveryMode !== "server") return cancel("local_delivery");
  if (!subscription?.enabled) return cancel("subscription_removed");
  if (
    reminder.eventID !== bundle.event.id ||
    subscription.eventID !== bundle.event.id
  ) {
    return cancel("event_mismatch");
  }
  if (bundle.event.status === "cancelled") return cancel("event_cancelled");

  const round = bundle.ticketRounds.find(
    (candidate) => candidate.id === reminder.entityID,
  );
  if (!round) return cancel("entity_removed");
  if (round.status !== "confirmed") return cancel("deadline_unconfirmed");
  const rawDeadline = round[reminder.deadlineField];
  if (rawDeadline === null || rawDeadline === undefined)
    return cancel("deadline_removed");

  const deadline = new Date(rawDeadline);
  if (!Number.isFinite(deadline.getTime())) return cancel("invalid_deadline");
  if (deadline.getTime() <= now.getTime()) return cancel("deadline_elapsed");
  if (
    round.scope.kind !== "performances" ||
    round.scope.performanceIDs.length === 0
  ) {
    return cancel("scope_unconfirmed");
  }

  const knownPerformances = new Map(
    bundle.performances.map((performance) => [performance.id, performance]),
  );
  const scopedPerformances = [...new Set(round.scope.performanceIDs)].filter(
    (id) => knownPerformances.has(id),
  );
  if (scopedPerformances.length === 0) return cancel("scope_unconfirmed");

  if (
    reminder.performanceID &&
    !knownPerformances.has(reminder.performanceID)
  ) {
    return cancel("performance_removed");
  }

  const subscribed = subscription.performanceIDs;
  let matchedPerformances =
    !subscribed || subscribed.length === 0
      ? scopedPerformances
      : scopedPerformances.filter((id) => subscribed.includes(id));
  if (reminder.performanceID) {
    matchedPerformances = matchedPerformances.filter(
      (id) => id === reminder.performanceID,
    );
  }
  if (matchedPerformances.length === 0) return cancel("scope_not_subscribed");

  const activePerformances = matchedPerformances.filter(
    (id) => knownPerformances.get(id)?.status !== "cancelled",
  );
  if (activePerformances.length === 0) return cancel("performances_cancelled");

  if (
    !Number.isSafeInteger(reminder.offsetSeconds) ||
    reminder.offsetSeconds < 0
  ) {
    throw new RangeError("offsetSeconds must be a non-negative safe integer");
  }
  const intendedSchedule = deadline.getTime() - reminder.offsetSeconds * 1_000;
  // A newly published correction should still be delivered while its deadline is live.
  const scheduledAt = new Date(Math.max(intendedSchedule, now.getTime()));
  const deadlineRevision = makeDeadlineRevision({
    entityID: reminder.entityID,
    deadlineField: reminder.deadlineField,
    deadlineAt: deadline.toISOString(),
    performanceIDs: activePerformances,
  });

  return {
    action: "schedule",
    reminderID: reminder.id,
    installationID: reminder.installationID,
    eventID: reminder.eventID,
    entityID: reminder.entityID,
    deadlineAt: deadline.toISOString(),
    scheduledAt: scheduledAt.toISOString(),
    contentRevision: bundle.revision,
    deadlineRevision,
    triggerType: reminder.triggerType,
    performanceIDs: activePerformances.sort(),
    deliveryKey: makeDeliveryKey({
      installationID: reminder.installationID,
      reminderID: reminder.id,
      deadlineRevision,
      triggerType: reminder.triggerType,
    }),
  };
}
