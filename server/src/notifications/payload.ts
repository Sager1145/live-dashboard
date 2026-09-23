import type { NotificationContent } from "./types.js";

export interface ApnsPayload {
  readonly aps: {
    readonly alert: { readonly title: string; readonly body: string };
    readonly sound?: "default";
    readonly "thread-id": string;
  };
  readonly notificationID: string;
  readonly eventID: string;
  readonly editionID?: string;
  readonly stopID?: string;
  readonly performanceID?: string;
  readonly tab: "overview" | "tickets" | "seating" | "goods";
  readonly cardKey: string;
  readonly revision: string | number;
}

export function buildNotificationPayload(
  content: NotificationContent,
): ApnsPayload {
  const { deepLink } = content;
  return {
    aps: {
      alert: { title: content.title, body: content.body },
      ...(content.sound ? { sound: content.sound } : {}),
      "thread-id": deepLink.eventID,
    },
    notificationID: deepLink.notificationID,
    eventID: deepLink.eventID,
    ...(deepLink.editionID ? { editionID: deepLink.editionID } : {}),
    ...(deepLink.stopID ? { stopID: deepLink.stopID } : {}),
    ...(deepLink.performanceID
      ? { performanceID: deepLink.performanceID }
      : {}),
    tab: deepLink.tab,
    cardKey: deepLink.cardKey,
    revision: deepLink.revision,
  };
}
