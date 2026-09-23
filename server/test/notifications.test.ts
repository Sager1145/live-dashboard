import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { describe, it } from "node:test";

import {
  ApnsTransport,
  buildNotificationPayload,
  makeDeadlineRevision,
  makeDeliveryKey,
  parseRetryAfter,
  reconcileReminder,
  type ApnsMessage,
  type LatestPublishedBundle,
  type ServerDeadlineReminder,
} from "../src/notifications/index.js";

const now = new Date("2026-09-22T12:00:00.000Z");

function bundle(
  overrides: Partial<LatestPublishedBundle> = {},
): LatestPublishedBundle {
  return {
    revision: 7,
    publishedAt: "2026-09-22T11:00:00.000Z",
    event: { id: "event-1", status: "scheduled" },
    performances: [{ id: "perf-1" }, { id: "perf-2" }],
    ticketRounds: [
      {
        id: "round-1",
        applyEndAt: "2026-09-25T12:00:00.000Z",
        status: "confirmed",
        scope: { kind: "performances", performanceIDs: ["perf-2", "perf-1"] },
      },
    ],
    ...overrides,
  };
}

const reminder: ServerDeadlineReminder = {
  id: "reminder-1",
  installationID: "installation-1",
  eventID: "event-1",
  entityID: "round-1",
  deadlineField: "applyEndAt",
  offsetSeconds: 86_400,
  enabled: true,
  deliveryMode: "server",
  triggerType: "deadline",
};

const subscription = {
  eventID: "event-1",
  enabled: true,
  performanceIDs: ["perf-1"],
} as const;

describe("reminder reconciliation", () => {
  it("schedules only a confirmed deadline in the subscribed scope", () => {
    const plan = reconcileReminder({
      bundle: bundle(),
      reminder,
      subscription,
      now,
    });
    assert.equal(plan.action, "schedule");
    if (plan.action !== "schedule") return;
    assert.equal(plan.scheduledAt, "2026-09-24T12:00:00.000Z");
    assert.deepEqual(plan.performanceIDs, ["perf-1"]);
    assert.equal(plan.contentRevision, 7);
    assert.equal(
      plan.deadlineRevision,
      makeDeadlineRevision({
        entityID: "round-1",
        deadlineField: "applyEndAt",
        deadlineAt: "2026-09-25T12:00:00.000Z",
        performanceIDs: ["perf-1"],
      }),
    );
    assert.equal(
      plan.deliveryKey,
      makeDeliveryKey({
        installationID: "installation-1",
        reminderID: "reminder-1",
        deadlineRevision: plan.deadlineRevision,
        triggerType: "deadline",
      }),
    );
  });

  it("does not rotate the delivery key for an unrelated bundle revision", () => {
    const first = reconcileReminder({
      bundle: bundle(),
      reminder,
      subscription,
      now,
    });
    const replay = reconcileReminder({
      bundle: bundle(),
      reminder,
      subscription,
      now,
    });
    const changed = reconcileReminder({
      bundle: bundle({ revision: 8 }),
      reminder,
      subscription,
      now,
    });
    assert.equal(first.action, "schedule");
    assert.equal(replay.action, "schedule");
    assert.equal(changed.action, "schedule");
    if (
      first.action === "schedule" &&
      replay.action === "schedule" &&
      changed.action === "schedule"
    ) {
      assert.equal(first.deliveryKey, replay.deliveryKey);
      assert.equal(first.deliveryKey, changed.deliveryKey);
      assert.notEqual(first.contentRevision, changed.contentRevision);
    }
  });

  it("rotates the delivery key when the deadline or effective scope changes", () => {
    const first = reconcileReminder({
      bundle: bundle(),
      reminder,
      subscription,
      now,
    });
    const changedDeadline = reconcileReminder({
      bundle: bundle({
        revision: 8,
        ticketRounds: [
          {
            id: "round-1",
            applyEndAt: "2026-09-26T12:00:00.000Z",
            status: "confirmed",
            scope: {
              kind: "performances",
              performanceIDs: ["perf-1", "perf-2"],
            },
          },
        ],
      }),
      reminder,
      subscription,
      now,
    });
    const changedScope = reconcileReminder({
      bundle: bundle(),
      reminder,
      subscription: { eventID: "event-1", enabled: true },
      now,
    });
    assert.equal(first.action, "schedule");
    assert.equal(changedDeadline.action, "schedule");
    assert.equal(changedScope.action, "schedule");
    if (
      first.action === "schedule" &&
      changedDeadline.action === "schedule" &&
      changedScope.action === "schedule"
    ) {
      assert.notEqual(first.deliveryKey, changedDeadline.deliveryKey);
      assert.notEqual(first.deliveryKey, changedScope.deliveryKey);
    }
  });

  it("supports payment deadlines and an explicit performance target", () => {
    const paymentReminder: ServerDeadlineReminder = {
      ...reminder,
      deadlineField: "paymentDeadlineAt",
      performanceID: "perf-2",
    };
    const paymentBundle = bundle({
      ticketRounds: [
        {
          id: "round-1",
          applyEndAt: "2026-09-25T12:00:00.000Z",
          paymentDeadlineAt: "2026-09-28T12:00:00.000Z",
          status: "confirmed",
          scope: { kind: "performances", performanceIDs: ["perf-1", "perf-2"] },
        },
      ],
    });
    const plan = reconcileReminder({
      bundle: paymentBundle,
      reminder: paymentReminder,
      subscription: { eventID: "event-1", enabled: true },
      now,
    });
    assert.equal(plan.action, "schedule");
    if (plan.action === "schedule") {
      assert.equal(plan.deadlineAt, "2026-09-28T12:00:00.000Z");
      assert.deepEqual(plan.performanceIDs, ["perf-2"]);
    }
  });

  it("cancels queued work when its event or subscription is removed", () => {
    assert.deepEqual(
      reconcileReminder({
        bundle: bundle(),
        reminder,
        subscription: null,
        now,
      }),
      {
        action: "cancel",
        reminderID: "reminder-1",
        reason: "subscription_removed",
      },
    );
    assert.deepEqual(
      reconcileReminder({
        bundle: bundle({ event: { id: "event-1", status: "cancelled" } }),
        reminder,
        subscription,
        now,
      }),
      { action: "cancel", reminderID: "reminder-1", reason: "event_cancelled" },
    );
  });

  it("rejects unconfirmed, removed, and out-of-scope deadlines", () => {
    const unconfirmed = bundle({
      ticketRounds: [
        {
          id: "round-1",
          applyEndAt: "2026-09-25T12:00:00.000Z",
          status: "needsReview",
          scope: { kind: "performances", performanceIDs: ["perf-1"] },
        },
      ],
    });
    assert.equal(
      reconcileReminder({ bundle: unconfirmed, reminder, subscription, now })
        .action,
      "cancel",
    );
    assert.deepEqual(
      reconcileReminder({
        bundle: bundle({ ticketRounds: [] }),
        reminder,
        subscription,
        now,
      }),
      { action: "cancel", reminderID: "reminder-1", reason: "entity_removed" },
    );
    assert.deepEqual(
      reconcileReminder({
        bundle: bundle(),
        reminder,
        subscription: {
          eventID: "event-1",
          enabled: true,
          performanceIDs: ["missing"],
        },
        now,
      }),
      {
        action: "cancel",
        reminderID: "reminder-1",
        reason: "scope_not_subscribed",
      },
    );
  });

  it("delivers immediately after a late reconciliation while the deadline is still live", () => {
    const late = reconcileReminder({
      bundle: bundle(),
      reminder: { ...reminder, offsetSeconds: 7 * 86_400 },
      subscription,
      now,
    });
    assert.equal(late.action, "schedule");
    if (late.action === "schedule")
      assert.equal(late.scheduledAt, now.toISOString());
  });
});

const deepLink = {
  notificationID: "notification-1",
  eventID: "event-1",
  editionID: "edition-1",
  stopID: "stop-1",
  performanceID: "perf-1",
  tab: "tickets" as const,
  cardKey: "ticket-round:round-1",
  revision: 7,
};

const message: ApnsMessage = {
  deviceToken: "a".repeat(64),
  notification: {
    title: "受付終了間近",
    body: "締切を確認してください",
    deepLink,
    sound: "default",
  },
  expiration: new Date("2026-09-25T12:00:00.000Z"),
  collapseID: "reminder-1",
};

describe("APNs payload", () => {
  it("contains the complete event/performance/tab/card deep link", () => {
    const payload = buildNotificationPayload(message.notification);
    assert.equal(payload.eventID, "event-1");
    assert.equal(payload.editionID, "edition-1");
    assert.equal(payload.stopID, "stop-1");
    assert.equal(payload.performanceID, "perf-1");
    assert.equal(payload.tab, "tickets");
    assert.equal(payload.cardKey, "ticket-round:round-1");
    assert.equal(payload.revision, 7);
  });
});

describe("APNs transport", () => {
  const keys = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const privateKey = keys.privateKey
    .export({ type: "pkcs8", format: "pem" })
    .toString();
  const credentials = {
    teamID: "TEAM123",
    keyID: "KEY123",
    privateKey,
    topic: "app.live-dashboard",
  };

  it("does not report success when credentials are absent", async () => {
    let called = false;
    const transport = new ApnsTransport(
      { environment: "development", credentials: {} },
      {
        execute: async () => {
          called = true;
          throw new Error("must not execute");
        },
      },
    );
    assert.deepEqual(await transport.send(message), {
      outcome: "failed",
      reason: "MissingApnsTeamID",
      attempts: 0,
    });
    assert.equal(called, false);
  });

  it("does not retry or report success for a malformed signing key", async () => {
    const transport = new ApnsTransport({
      environment: "development",
      credentials: { ...credentials, privateKey: "not-a-private-key" },
    });
    assert.deepEqual(await transport.send(message), {
      outcome: "failed",
      reason: "InvalidApnsPrivateKey",
      attempts: 0,
    });
  });

  it("signs ES256 provider tokens and selects the sandbox endpoint", async () => {
    let capturedAuthorization = "";
    const transport = new ApnsTransport(
      { environment: "development", credentials },
      {
        now: () => now,
        execute: async (request) => {
          assert.equal(request.origin, "https://api.sandbox.push.apple.com");
          assert.equal(request.headers["apns-topic"], "app.live-dashboard");
          assert.equal(request.headers["apns-collapse-id"], "reminder-1");
          capturedAuthorization = String(request.headers.authorization);
          return { status: 200, headers: { "apns-id": "apns-1" }, body: "" };
        },
      },
    );
    assert.deepEqual(await transport.send(message), {
      outcome: "sent",
      apnsID: "apns-1",
      attempts: 1,
    });
    const token = capturedAuthorization.replace(/^bearer /, "");
    const [header, claims, signature] = token.split(".");
    assert.deepEqual(JSON.parse(Buffer.from(header!, "base64url").toString()), {
      alg: "ES256",
      kid: "KEY123",
    });
    assert.deepEqual(JSON.parse(Buffer.from(claims!, "base64url").toString()), {
      iss: "TEAM123",
      iat: Math.floor(now.getTime() / 1_000),
    });
    assert.equal(
      verify(
        "sha256",
        Buffer.from(`${header}.${claims}`),
        { key: keys.publicKey, dsaEncoding: "ieee-p1363" },
        Buffer.from(signature!, "base64url"),
      ),
      true,
    );
  });

  it("rotates rejected provider tokens and uses the production endpoint", async () => {
    let current = now.getTime();
    const tokens: string[] = [];
    const transport = new ApnsTransport(
      { environment: "production", credentials, maxAttempts: 2 },
      {
        now: () => new Date(current),
        execute: async (request) => {
          assert.equal(request.origin, "https://api.push.apple.com");
          tokens.push(String(request.headers.authorization));
          if (tokens.length === 1) {
            current += 1_000;
            return {
              status: 403,
              headers: {},
              body: '{"reason":"ExpiredProviderToken"}',
            };
          }
          return { status: 200, headers: {}, body: "" };
        },
      },
    );
    assert.deepEqual(await transport.send(message), {
      outcome: "sent",
      attempts: 2,
    });
    assert.notEqual(tokens[0], tokens[1]);
  });

  it("marks permanent device-token failures for cleanup", async () => {
    const transport = new ApnsTransport(
      { environment: "production", credentials },
      {
        execute: async () => ({
          status: 410,
          headers: {},
          body: '{"reason":"Unregistered","timestamp":1789992000}',
        }),
      },
    );
    const result = await transport.send(message);
    assert.equal(result.outcome, "invalid_token");
    if (result.outcome === "invalid_token") {
      assert.equal(result.reason, "Unregistered");
      assert.equal(result.invalidatedAt, "2026-09-21T12:00:00.000Z");
    }
  });

  it("honors Retry-After with a finite retry budget", async () => {
    const sleeps: number[] = [];
    let calls = 0;
    const transport = new ApnsTransport(
      {
        environment: "production",
        credentials,
        maxAttempts: 3,
        maxBackoffMs: 10_000,
      },
      {
        now: () => now,
        sleep: async (milliseconds) => {
          sleeps.push(milliseconds);
        },
        execute: async () => {
          calls += 1;
          return {
            status: 429,
            headers: { "retry-after": "3" },
            body: '{"reason":"TooManyRequests"}',
          };
        },
      },
    );
    assert.deepEqual(await transport.send(message), {
      outcome: "retry",
      reason: "TooManyRequests",
      attempts: 3,
      retryAfterMs: 3_000,
    });
    assert.equal(calls, 3);
    assert.deepEqual(sleeps, [3_000, 3_000]);
  });

  it("parses both Retry-After formats", () => {
    assert.equal(parseRetryAfter("5", now), 5_000);
    assert.equal(parseRetryAfter("Tue, 22 Sep 2026 12:00:07 GMT", now), 7_000);
    assert.equal(parseRetryAfter("nonsense", now), null);
  });
});
