import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { claim, complete, enqueueUpdateJob } from "../src/queue.js";
import {
  buildSectionGraph,
  identityTableFromParse,
} from "../src/ingestion/section-graph.js";
import { makeSnapshot } from "../src/ingestion/snapshot.js";
import { parseSnapshot } from "../src/ingestion/parser.js";
import type { ParseResult, SourceSnapshot } from "../src/ingestion/types.js";
import {
  bundlesInServerScanWindow,
  serverScanCutoff,
  tourIsArchived,
} from "../src/refresh-policy.js";
import {
  currentUpdateSlot,
  parseAndStore,
  registerDocument,
  runFetchJob,
  runUpdateSlotJob,
  saveSnapshot,
  scheduleSources,
  scheduleUpdateSlot,
} from "../src/ingestion-worker.js";
import { testDB } from "./support.js";

const PAGE = `<!doctype html><html><body><main>
<h1 id="title">Tokyo two days</h1>
<p>intro stays together</p>
<h2 id="goods">Goods</h2>
<ul><li><a href="https://example.com/shop">shop</a></li></ul>
<img alt="towel" src="/towel.jpg">
<table>
<tr><th>Name</th><th>Price</th></tr>
<tr><td>Pen</td><td>500</td></tr>
<tr><td>Towel</td><td>1000</td></tr>
</table>
</main></body></html>`;

function snapshot(html: string, id = "doc-1"): SourceSnapshot {
  return makeSnapshot({
    sourceDocumentId: id,
    fetchUrl: "https://example.com/events/a",
    finalUrl: "https://example.com/events/a",
    statusCode: 200,
    headers: { "content-type": "text/html" },
    body: Buffer.from(html),
  });
}

function parsed(performanceId?: string, localDate = "2026-10-10"): ParseResult {
  return {
    candidates: [
      {
        entityRef: {
          sourceKey: "example.com/events/a#performance:DAY1",
          ...(performanceId ? { performanceId } : {}),
        },
        field: "performance.schedule",
        value: { localDate, dayLabel: "DAY1" },
        applicability: performanceId
          ? { kind: "performances", performanceIds: [performanceId] }
          : { kind: "unresolved", rawText: "DAY1" },
        sourceSnapshotId: "snap",
        evidence: {
          sectionPath: ["日程"],
          locator: "schedule",
          rawText: localDate,
          sourceLanguage: "ja",
        },
        extractionMethod: "dom",
        parserVersion: "1.0.0",
      },
    ],
    media: [],
    links: [],
    sections: [],
    issues: [],
  };
}

test("DOM sections keep structure, stable block ids, and parent scope dependencies", () => {
  const graph = buildSectionGraph(snapshot(PAGE), parsed());
  assert.ok(graph.blocks.length >= 4);
  assert.equal(
    graph.blocks.some((block) => block.kind === "heading" && block.anchor === "goods"),
    true,
  );
  const list = graph.blocks.find((block) => block.kind === "list");
  assert.ok(list);
  assert.equal(list.parentHeading, "Goods");
  assert.deepEqual(list.headingPath, ["Tokyo two days", "Goods"]);
  assert.match(list.domPath, /ul:nth-of-type/);
  assert.equal(list.links[0]?.href, "https://example.com/shop");
  assert.notEqual(list.blockID, list.contentHash);
  assert.equal(list.dependency.status, "resolved");
  const image = graph.blocks.find((block) => block.images.length > 0);
  assert.equal(image?.images[0]?.src, "https://example.com/towel.jpg");
  const rows = graph.blocks.filter((block) => block.kind === "table-row");
  assert.equal(rows.length, 2);
  assert.match(rows[0]!.text, /Name: Pen/);
  assert.match(rows[0]!.text, /Price: 500/);
  assert.doesNotMatch(rows[0]!.text, /Towel/);
  assert.match(rows[1]!.text, /Name: Towel/);
  const orders = graph.blocks.map((block) => block.sourceOrder);
  assert.deepEqual(orders, [...orders].sort((a, b) => a - b));
  const root = graph.blocks.find((block) => block.anchor === "title");
  assert.equal(root?.dependency.status, "unresolved");
  if (root?.dependency.status === "unresolved")
    assert.equal(root.dependency.reason, "parent_scope_not_visible");
  assert.equal(JSON.stringify(root?.dependency).includes("performance"), false);

  const renamed = buildSectionGraph(
    snapshot(PAGE.replace("Tokyo two days", "Osaka one day")),
    parsed(),
  );
  const renamedList = renamed.blocks.find((block) => block.kind === "list");
  assert.equal(renamedList?.blockID, list.blockID);
  assert.equal(renamedList?.contentHash, list.contentHash);
  assert.notEqual(
    renamedList?.dependency.status === "resolved"
      ? renamedList.dependency.dependencyHash
      : "",
    list.dependency.status === "resolved" ? list.dependency.dependencyHash : "",
  );

  const moved = buildSectionGraph(snapshot(PAGE), parsed(undefined, "2026-11-01"));
  const movedList = moved.blocks.find((block) => block.kind === "list");
  assert.equal(movedList?.blockID, list.blockID);
  assert.equal(movedList?.contentHash, list.contentHash);
  assert.notEqual(
    movedList?.dependency.status === "resolved"
      ? movedList.dependency.dependencyHash
      : "",
    list.dependency.status === "resolved" ? list.dependency.dependencyHash : "",
  );
  const identity = identityTableFromParse(parsed());
  assert.equal(identity.performances[0]?.performanceId, null);
  assert.equal(identity.stops.length, 0);
});

test("section splits follow elements, not character counts or blank lines", () => {
  const blank = buildSectionGraph(
    snapshot(
      "<!doctype html><html><body><main><p>line one\n\nline two</p></main></body></html>",
    ),
    parsed(),
  );
  assert.equal(blank.blocks.length, 1);
  assert.match(blank.blocks[0]!.text, /line one/);
  assert.match(blank.blocks[0]!.text, /line two/);
  const long = "word ".repeat(120);
  const parts = buildSectionGraph(
    snapshot(
      `<!doctype html><html><body><main><p>${long}</p><p>second paragraph</p></main></body></html>`,
    ),
    parsed(),
  );
  assert.equal(parts.blocks.length, 2);
  assert.equal(parts.blocks[0]!.text, long.trim());
  assert.equal(parts.blocks[1]!.text, "second paragraph");
});

test("stored section blocks can be read back from the snapshot", async () => {
  const db = await testDB();
  try {
    const doc = await registerDocument(db, "https://example.com/events/a");
    const stored = await saveSnapshot(
      db,
      makeSnapshot({
        sourceDocumentId: doc.id,
        fetchUrl: doc.fetch_url,
        finalUrl: doc.fetch_url,
        statusCode: 200,
        headers: { "content-type": "text/html" },
        body: Buffer.from(PAGE),
      }),
    );
    await parseAndStore(db, stored);
    const rows = (
      await db.query(
        "SELECT source_key, data FROM fact_candidates WHERE snapshot_id=$1 AND kind='dom.block' ORDER BY (data->>'sourceOrder')::int",
        [stored.id],
      )
    ).rows;
    const again = buildSectionGraph(stored, parseSnapshot(stored));
    assert.deepEqual(
      rows.map((row) => row.source_key),
      again.blocks.map((block) => block.blockID),
    );
    assert.equal(rows[0].data.blockID === rows[0].data.contentHash, false);
    assert.ok(rows.some((row) => row.data.dependency?.status === "resolved"));
    assert.ok(rows.some((row) => row.data.dependency?.status === "unresolved"));
  } finally {
    await db.close();
  }
});

test("304 fetch records checkedAt and does not insert a content snapshot", async () => {
  const db = await testDB();
  try {
    const origin = randomUUID();
    const doc = randomUUID();
    const snapshotID = randomUUID();
    await db.query(
      "INSERT INTO source_origins(id,origin,policy,next_allowed_at) VALUES($1,$2,$3,now()-interval '1 minute')",
      [
        origin,
        "https://example.com",
        JSON.stringify({
          enabled: true,
          reviewStatus: "approved",
          robotsCheckedAt: "2026-01-01T00:00:00.000Z",
          termsReviewedAt: "2026-01-01T00:00:00.000Z",
          host: "example.com",
          allowedPaths: ["/events"],
        }),
      ],
    );
    await db.query(
      "INSERT INTO source_documents(id,origin_id,fetch_url,identity_url,enabled) VALUES($1,$2,$3,$3,true)",
      [doc, origin, "https://example.com/events/a"],
    );
    await db.query(
      "INSERT INTO source_snapshots(id,document_id,content_hash,body,metadata) VALUES($1,$2,'hash',$3,$4)",
      [
        snapshotID,
        doc,
        "<!doctype html><html><main>known</main></html>",
        JSON.stringify({
          fetchUrl: "https://example.com/events/a",
          finalUrl: "https://example.com/events/a",
          headers: { etag: '"v1"' },
          statusCode: 200,
          fetchedAt: "2026-09-01T00:00:00.000Z",
          redirectChain: [],
        }),
      ],
    );
    await db.query(
      "UPDATE source_documents SET last_snapshot_id=$2 WHERE id=$1",
      [doc, snapshotID],
    );
    await db.query(
      "INSERT INTO jobs(id,kind,payload,dedupe_key) VALUES($1,'fetch',$2,$3)",
      [randomUUID(), JSON.stringify({ documentID: doc }), `fetch-304:${doc}`],
    );
    const checkedAt = "2026-09-24T12:00:00.000Z";
    assert.equal(
      await runFetchJob(db, async () => ({
        status: "unchanged",
        snapshot: snapshot("<!doctype html><html><main>known</main></html>"),
        validatedAt: checkedAt,
        checkedAt,
      })),
      true,
    );
    assert.equal(
      Number(
        (await db.query("SELECT count(*)::int AS n FROM source_snapshots"))
          .rows[0].n,
      ),
      1,
    );
    const fetch = (
      await db.query("SELECT outcome, metadata FROM source_fetches")
    ).rows[0];
    assert.equal(fetch.outcome, "unchanged");
    assert.equal(fetch.metadata.checkedAt, checkedAt);
    assert.equal(fetch.metadata.statusCode, 304);
    assert.equal(
      Number(
        (
          await db.query(
            "SELECT count(*)::int AS n FROM jobs WHERE kind='parse'",
          )
        ).rows[0].n,
      ),
      0,
    );
  } finally {
    await db.close();
  }
});

test("manual and scheduled jobs share an active target; card jobs wait without inventing ids", async () => {
  const db = await testDB();
  try {
    const manual = await enqueueUpdateJob(db, {
      target: { kind: "event", eventID: "event-1" },
      idempotencyKey: "manual-1",
      fetchLatest: true,
      reextract: false,
      reason: "owner_requested",
    });
    const scheduled = await enqueueUpdateJob(db, {
      target: { kind: "event", eventID: "event-1" },
      idempotencyKey: "schedule-1",
      fetchLatest: true,
      reextract: true,
      reason: "schedule",
    });
    assert.equal(scheduled.jobID, manual.jobID);
    assert.equal(scheduled.deduplicated, true);
    const retry = await enqueueUpdateJob(db, {
      target: { kind: "event", eventID: "event-1" },
      idempotencyKey: "manual-1",
      fetchLatest: true,
      reextract: false,
      reason: "owner_requested",
    });
    assert.equal(retry.jobID, manual.jobID);
    assert.equal(retry.deduplicated, true);
    assert.equal(
      Number((await db.query("SELECT count(*)::int AS n FROM jobs")).rows[0].n),
      1,
    );
    const running = await claim(db, "update");
    assert.ok(running);
    assert.equal(await complete(db, running.id, running.fencing_token), true);
    const retryDone = await enqueueUpdateJob(db, {
      target: { kind: "event", eventID: "event-1" },
      idempotencyKey: "manual-1",
      fetchLatest: true,
      reextract: false,
      reason: "owner_requested",
    });
    assert.equal(retryDone.jobID, manual.jobID);
    const next = await enqueueUpdateJob(db, {
      target: { kind: "event", eventID: "event-1" },
      idempotencyKey: "schedule-2",
      fetchLatest: false,
      reextract: true,
      reason: "schedule",
    });
    assert.notEqual(next.jobID, manual.jobID);
    assert.equal(next.deduplicated, false);
    const nextRun = await claim(db, "update");
    assert.equal(nextRun?.id, next.jobID);
    assert.equal(await complete(db, nextRun!.id, nextRun!.fencing_token), true);

    const waiting = await enqueueUpdateJob(db, {
      target: { kind: "card", eventID: "missing-event", cardID: "card-1" },
      idempotencyKey: "card-1",
      fetchLatest: true,
      reextract: true,
      reason: "owner_requested",
    });
    assert.equal(waiting.state, "waiting");
    assert.equal(await claim(db, "update"), null);
    const waitingRow = (
      await db.query("SELECT payload FROM jobs WHERE id=$1", [waiting.jobID])
    ).rows[0];
    assert.deepEqual(waitingRow.payload.dependency, {
      status: "unresolved",
      reason: "parent_identity_not_visible",
    });
    assert.equal("performanceIDs" in waitingRow.payload.dependency, false);

    await db.query(
      "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,1,$2,'hash')",
      [
        "event-no-id",
        JSON.stringify({
          performances: [{ localDate: "2027-01-01" }],
        }),
      ],
    );
    const stillWaiting = await enqueueUpdateJob(db, {
      target: { kind: "card", eventID: "event-no-id", cardID: "card-2" },
      idempotencyKey: "card-2",
      fetchLatest: true,
      reextract: false,
      reason: "owner_requested",
    });
    assert.equal(stillWaiting.state, "waiting");
    await db.query("UPDATE events SET bundle=$2 WHERE id=$1", [
      "event-no-id",
      JSON.stringify({
        performances: [{ id: "perf-later", localDate: "2027-01-01" }],
      }),
    ]);
    const resumed = await enqueueUpdateJob(db, {
      target: { kind: "card", eventID: "event-no-id", cardID: "card-2" },
      idempotencyKey: "card-2b",
      fetchLatest: true,
      reextract: false,
      reason: "schedule",
    });
    assert.equal(resumed.jobID, stillWaiting.jobID);
    assert.equal(resumed.deduplicated, true);
    assert.equal(resumed.state, "queued");
    const resumedRun = await claim(db, "update");
    assert.equal(resumedRun?.id, stillWaiting.jobID);
    assert.equal(
      await complete(db, resumedRun!.id, resumedRun!.fencing_token),
      true,
    );

    await db.query(
      "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,1,$2,'hash-2')",
      [
        "event-ready",
        JSON.stringify({
          performances: [{ id: "perf-stored", localDate: "2027-01-01" }],
        }),
      ],
    );
    const ready = await enqueueUpdateJob(db, {
      target: { kind: "card", eventID: "event-ready", cardID: "card-3" },
      idempotencyKey: "card-3",
      fetchLatest: true,
      reextract: false,
      reason: "schedule",
    });
    assert.equal(ready.state, "queued");
    const claimed = await claim(db, "update");
    assert.equal(claimed?.id, ready.jobID);
    assert.deepEqual(claimed?.payload.dependency, {
      status: "resolved",
      source: "stored_event",
    });
  } finally {
    await db.close();
  }
});

test("UTC update slots resume the unfinished run and reclaim an expired lease", async () => {
  const db = await testDB();
  try {
    assert.equal(
      currentUpdateSlot(new Date("2026-09-24T11:59:00.000Z")),
      "2026-09-24T00:00:00.000Z",
    );
    assert.equal(
      currentUpdateSlot(new Date("2026-09-24T12:00:00.000Z")),
      "2026-09-24T12:00:00.000Z",
    );
    const morning = await scheduleUpdateSlot(
      db,
      new Date("2026-09-24T01:00:00.000Z"),
    );
    const later = await scheduleUpdateSlot(
      db,
      new Date("2026-09-24T18:00:00.000Z"),
    );
    assert.equal(later.jobID, morning.jobID);
    assert.equal(later.resumed, true);
    assert.equal(later.slot, "2026-09-24T00:00:00.000Z");
    assert.equal(
      Number(
        (
          await db.query(
            "SELECT count(*)::int AS n FROM jobs WHERE kind='update_run'",
          )
        ).rows[0].n,
      ),
      1,
    );
    const first = await claim(db, "update_run", 30);
    assert.ok(first);
    await db.query(
      "UPDATE jobs SET lease_until=now()-interval '1 second' WHERE id=$1",
      [first.id],
    );
    const second = await claim(db, "update_run", 30);
    assert.ok(second);
    assert.equal(second.id, first.id);
    assert.notEqual(second.fencing_token, first.fencing_token);
    assert.equal(await complete(db, first.id, first.fencing_token), false);
    assert.equal(await complete(db, second.id, second.fencing_token), true);

    const next = await scheduleUpdateSlot(
      db,
      new Date("2026-09-24T18:00:00.000Z"),
    );
    assert.equal(next.created, true);
    assert.equal(next.slot, "2026-09-24T12:00:00.000Z");
    assert.equal(await runUpdateSlotJob(db), true);
    const done = (
      await db.query("SELECT status FROM jobs WHERE id=$1", [next.jobID])
    ).rows[0];
    assert.equal(done.status, "done");
    const slots = (
      await db.query(
        "SELECT payload->>'slot' AS slot FROM jobs WHERE kind='update_run' ORDER BY 1",
      )
    ).rows.map((row) => row.slot);
    assert.deepEqual(slots, [
      "2026-09-24T00:00:00.000Z",
      "2026-09-24T12:00:00.000Z",
    ]);
  } finally {
    await db.close();
  }
});

test("server scan window uses the Japan calendar and archives only a finished tour", async () => {
  const evening = new Date("2026-09-24T16:00:00.000Z");
  assert.equal(serverScanCutoff(evening), "2026-08-25");
  assert.equal(
    serverScanCutoff(new Date("2026-03-30T15:00:00.000Z")),
    "2026-02-28",
  );
  assert.equal(
    serverScanCutoff(new Date("2024-03-30T15:00:00.000Z")),
    "2024-02-29",
  );
  const now = new Date("2026-09-24T03:00:00.000Z");
  assert.equal(tourIsArchived([{ localDate: "2026-08-23" }], now), true);
  assert.equal(tourIsArchived([{ localDate: "2026-08-24" }], now), false);
  assert.equal(
    tourIsArchived(
      [{ localDate: "2020-01-01" }, { localDate: null }],
      now,
    ),
    false,
  );
  assert.equal(
    tourIsArchived(
      [{ localDate: "2020-01-01" }, { localDate: "2027-01-01" }],
      now,
    ),
    false,
  );
  assert.equal(tourIsArchived([], now), false);
  assert.equal(bundlesInServerScanWindow([], now), true);

  const db = await testDB();
  try {
    const origin = randomUUID();
    const oldDoc = randomUUID();
    const liveDoc = randomUUID();
    const url = (id: string) => `https://example.com/events/${id}`;
    await db.query(
      "INSERT INTO source_origins(id,origin,policy) VALUES($1,'https://example.com',$2)",
      [
        origin,
        JSON.stringify({ enabled: true, reviewStatus: "approved" }),
      ],
    );
    for (const id of [oldDoc, liveDoc])
      await db.query(
        "INSERT INTO source_documents(id,origin_id,fetch_url,identity_url,enabled,next_fetch_at) VALUES($1,$2,$3,$3,true,now())",
        [id, origin, url(id)],
      );
    const insertEvent = async (id: string, doc: string, localDate: string | null) =>
      db.query(
        "INSERT INTO events(id,revision,bundle,content_hash) VALUES($1,1,$2,$3)",
        [
          id,
          JSON.stringify({
            event: { primarySourceURL: url(doc) },
            performances: [{ id: `${id}-p`, localDate }],
          }),
          id,
        ],
      );
    await insertEvent("old-tour", oldDoc, "2020-01-01");
    await insertEvent("live-tour", liveDoc, null);
    assert.equal(await scheduleSources(db, now), 1);
    const jobs = (
      await db.query("SELECT payload FROM jobs WHERE kind='fetch'")
    ).rows;
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].payload.documentID, liveDoc);
  } finally {
    await db.close();
  }
});
