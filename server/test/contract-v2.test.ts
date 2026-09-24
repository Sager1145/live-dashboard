import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { ZodError } from "zod";
import {
  acceptEventRevision,
  apnsCatalogInvalidationSchema,
  canCommitCursor,
  compareDecimalCursor,
  DomainError,
  mergeProposedField,
  parseAIPatch,
  parseBundle,
  parseBundleV2,
  parseCatalogChanges,
  performanceStartInstant,
  updateJobRequestSchema,
  aiTaskSchema,
} from "../src/contracts.js";

async function v2Fixture() {
  return parseBundleV2(
    JSON.parse(await readFile("../fixtures/contracts/bundle-v2.json", "utf8")),
  );
}

test("v1 fixture stays on schemaVersion 1 and v2 adds the frozen envelope", async () => {
  const v1 = parseBundle(
    JSON.parse(await readFile("../fixtures/contracts/bundle-v1.json", "utf8")),
  );
  assert.equal(v1.schemaVersion, 1);
  const v2 = await v2Fixture();
  assert.equal(v2.schemaVersion, 2);
  assert.equal(v2.event.id, v1.event.id);
  assert.equal(v2.performances[0]?.localTime, "14:00");
  assert.equal(v2.performances[1]?.localTime, "19:00");
  assert.equal(v2.fieldAbsences[0]?.absence, "notAnnounced");
  assert.deepEqual(v2.mediaManifest.assets, []);
});

test("a placeholder change bundle is not a contract fixture", async () => {
  const bundle = await v2Fixture();
  assert.throws(
    () =>
      parseCatalogChanges({
        schemaVersion: 2,
        serverInstanceID: "server-demo-1",
        fromCursor: "180",
        cursor: "184",
        watermark: "190",
        hasMore: false,
        nextPageToken: null,
        changes: [
          {
            sequence: "184",
            kind: "upsert",
            eventID: bundle.event.id,
            revision: bundle.revision,
            bundle: { exampleOnly: "not a bundle" },
          },
        ],
        sourceHealth: {},
      }),
    ZodError,
  );
});

test("catalog window keeps cursor order and requires the saved bundle", async () => {
  const bundle = await v2Fixture();
  const doc = parseCatalogChanges({
    schemaVersion: 2,
    serverInstanceID: "server-demo-1",
    fromCursor: "180",
    cursor: "184",
    watermark: "190",
    hasMore: true,
    nextPageToken: "opaque-page-token",
    changes: [
      {
        sequence: "184",
        kind: "upsert",
        eventID: bundle.event.id,
        revision: bundle.revision,
        bundle,
      },
    ],
    sourceHealth: { [bundle.event.id]: "healthy" },
  });
  assert.equal(compareDecimalCursor("99", "184"), -1);
  assert.equal(
    canCommitCursor(new Set([bundle.event.id]), [bundle.event.id]),
    true,
  );
  const change = doc.changes[0];
  assert.equal(change?.kind, "upsert");
  if (change?.kind === "upsert")
    assert.equal(canCommitCursor(new Set(), [change.eventID]), false);
  assert.throws(
    () =>
      parseCatalogChanges({
        ...doc,
        changes: [{ sequence: "184", kind: "invented" }],
      }),
    ZodError,
  );
});

test("revision, null proposals, and unknown local time stay explicit", () => {
  acceptEventRevision(8, 8);
  assert.throws(() => acceptEventRevision(8, 7), DomainError);
  assert.equal(
    mergeProposedField("verified", null, { verified: false }),
    "verified",
  );
  assert.equal(mergeProposedField("verified", null, { verified: true }), null);
  assert.equal(
    performanceStartInstant({
      localDate: "2027-01-01",
      localTime: null,
      knownInstant: null,
    }),
    null,
  );
});

test("jobs accept only registered targets and model patches cannot widen scope or add links", () => {
  const job = updateJobRequestSchema.parse({
    target: { kind: "eventSection", eventID: "event-demo-1", section: "goods" },
    fetchLatest: true,
    reextract: true,
    reason: "owner_requested",
  });
  assert.equal(job.target.kind, "eventSection");
  assert.throws(() =>
    updateJobRequestSchema.parse({
      target: { kind: "url", url: "https://evil.example" },
      fetchLatest: true,
      reextract: true,
      reason: "owner_requested",
    }),
  );
  const task = aiTaskSchema.parse({
    taskID: "task-demo-1",
    taskType: "goods",
    schemaVersion: 2,
    eventID: "event-demo-1",
    baseRevision: 7,
    snapshotID: "snapshot-demo-1",
    blockIDs: ["block-goods-1"],
    scopeContext: {
      allowedPerformanceIDs: ["performance-day-1"],
      parentHeading: "公演共通グッズ",
    },
    allowedLinkIDs: ["link-shop-1"],
    allowedImageIDs: ["image-catalog-1"],
    allowedFields: ["officialName", "scope", "links", "mediaAssetIDs"],
    inputText: "shop https://example.org/shop",
  });
  const accepted = parseAIPatch(task, {
    taskID: task.taskID,
    patches: [
      {
        recordKind: "goodsCampaign",
        recordRef: "candidate-campaign-1",
        field: "mediaAssetIDs",
        value: ["image-catalog-1"],
        evidenceRefs: ["evidence-block-goods-1"],
        state: "proposed",
      },
    ],
    unresolved: [],
  });
  assert.equal(accepted.patches[0]?.state, "proposed");
  assert.throws(
    () =>
      parseAIPatch(task, {
        taskID: task.taskID,
        patches: [
          {
            recordKind: "goodsCampaign",
            recordRef: "candidate-campaign-1",
            field: "scope",
            value: {
              kind: "performances",
              performanceIDs: ["performance-not-allowed"],
            },
            evidenceRefs: ["evidence-block-goods-1"],
            state: "proposed",
          },
        ],
        unresolved: [],
      }),
    DomainError,
  );
  assert.throws(
    () =>
      parseAIPatch(task, {
        taskID: task.taskID,
        patches: [
          {
            recordKind: "goodsCampaign",
            recordRef: "candidate-campaign-1",
            field: "officialName",
            value: "https://evil.example/drop",
            evidenceRefs: ["evidence-block-goods-1"],
            state: "proposed",
          },
        ],
        unresolved: [],
      }),
    DomainError,
  );
  assert.throws(() =>
    parseAIPatch(task, {
      taskID: task.taskID,
      patches: [
        {
          recordKind: "goodsCampaign",
          recordRef: "candidate-campaign-1",
          field: "officialName",
          value: "name",
          evidenceRefs: ["evidence-block-goods-1"],
          state: "verified",
          thought: "hidden",
        },
      ],
      unresolved: [],
    }),
  );
});

test("applicability is only for an unconfirmed scope", async () => {
  const raw = JSON.parse(
    await readFile("../fixtures/contracts/bundle-v2.json", "utf8"),
  );
  raw.applicability = [
    {
      recordID: raw.performances[0].id,
      code: "rangeNotInSource",
      detail: "父标题没有给出场次",
    },
  ];
  assert.throws(() => parseBundleV2(raw), DomainError);
});

test("silent push carries a watermark and not a cursor", () => {
  const payload = apnsCatalogInvalidationSchema.parse({
    aps: { "content-available": 1 },
    serverInstanceID: "server-demo-1",
    catalogWatermark: "190",
  });
  assert.equal("cursor" in payload, false);
});
