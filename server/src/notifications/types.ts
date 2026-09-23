export type KnowledgeStatus =
  | "confirmed"
  | "officiallyTBA"
  | "notFetched"
  | "needsReview"
  | "notApplicable"
  | "officially_tba"
  | "not_collected"
  | "needs_review"
  | "not_applicable";

export type EventStatus =
  | "scheduled"
  | "finished"
  | "announced"
  | "on_sale"
  | "upcoming"
  | "in_progress"
  | "ended"
  | "postponed"
  | "cancelled";

export type ReminderScope =
  | {
      readonly kind: "performances";
      readonly performanceIDs: readonly string[];
    }
  | { readonly kind: "wholeEvent" }
  | { readonly kind: "unconfirmed" };

export interface PublishedTicketRound {
  readonly id: string;
  readonly applyEndAt: string | null;
  readonly paymentDeadlineAt?: string | null;
  readonly status: KnowledgeStatus;
  readonly scope: ReminderScope;
}

export interface PublishedPerformance {
  readonly id: string;
  readonly editionID?: string | null;
  readonly stopID?: string | null;
  readonly status?: EventStatus;
}

/**
 * The notification worker must receive the latest committed public bundle.
 * Candidate and review data deliberately do not satisfy this interface.
 */
export interface LatestPublishedBundle {
  readonly revision: string | number;
  readonly publishedAt: string;
  readonly event: {
    readonly id: string;
    readonly status: EventStatus;
  };
  readonly performances: readonly PublishedPerformance[];
  readonly ticketRounds: readonly PublishedTicketRound[];
}

export interface ServerDeadlineReminder {
  readonly id: string;
  readonly installationID: string;
  readonly eventID: string;
  readonly entityID: string;
  readonly performanceID?: string;
  readonly deadlineField: "applyEndAt" | "paymentDeadlineAt";
  readonly offsetSeconds: number;
  readonly enabled: boolean;
  readonly deliveryMode: "server" | "local";
  readonly triggerType: "deadline";
}

export interface InstallationSubscription {
  readonly eventID: string;
  readonly enabled: boolean;
  /** Omit or leave empty to subscribe to every performance in the event. */
  readonly performanceIDs?: readonly string[];
}

export type ReminderCancellationReason =
  | "reminder_disabled"
  | "local_delivery"
  | "subscription_removed"
  | "event_mismatch"
  | "event_cancelled"
  | "entity_removed"
  | "deadline_unconfirmed"
  | "deadline_removed"
  | "invalid_deadline"
  | "deadline_elapsed"
  | "scope_unconfirmed"
  | "scope_not_subscribed"
  | "performance_removed"
  | "performances_cancelled";

export type ReminderPlan =
  | {
      readonly action: "schedule";
      readonly reminderID: string;
      readonly installationID: string;
      readonly eventID: string;
      readonly entityID: string;
      readonly deadlineAt: string;
      readonly scheduledAt: string;
      /** Bundle revision checked again by the worker before sending. */
      readonly contentRevision: string | number;
      /** Stable hash of the deadline field, instant, and effective scope. */
      readonly deadlineRevision: string;
      readonly triggerType: "deadline";
      readonly performanceIDs: readonly string[];
      readonly deliveryKey: string;
    }
  | {
      readonly action: "cancel";
      readonly reminderID: string;
      readonly reason: ReminderCancellationReason;
    };

export interface NotificationDeepLink {
  readonly notificationID: string;
  readonly eventID: string;
  readonly editionID?: string;
  readonly stopID?: string;
  readonly performanceID?: string;
  readonly tab: "overview" | "tickets" | "seating" | "goods";
  readonly cardKey: string;
  readonly revision: string | number;
}

export interface NotificationContent {
  readonly title: string;
  readonly body: string;
  readonly deepLink: NotificationDeepLink;
  readonly sound?: "default";
}

export interface ApnsMessage {
  readonly deviceToken: string;
  readonly notification: NotificationContent;
  readonly expiration: Date;
  readonly collapseID: string;
  readonly priority?: 5 | 10;
}

export type ApnsSendResult =
  | {
      readonly outcome: "sent";
      readonly apnsID?: string;
      readonly attempts: number;
    }
  | {
      readonly outcome: "invalid_token";
      readonly reason: string;
      readonly attempts: number;
      readonly invalidatedAt?: string;
    }
  | {
      readonly outcome: "retry";
      readonly reason: string;
      readonly attempts: number;
      readonly retryAfterMs: number;
    }
  | {
      readonly outcome: "failed";
      readonly reason: string;
      readonly attempts: number;
      readonly status?: number;
    };
