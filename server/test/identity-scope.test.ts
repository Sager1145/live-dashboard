import test from "node:test";
import assert from "node:assert/strict";
import { IdentityRegistry } from "../src/identity.js";
import {
  assertNoInventedInstant,
  explicitLocalTime,
  inheritScope,
  materializeScope,
  ticketDeadline,
} from "../src/publication-scope.js";

const officialURL = "https://official.example/live";

test("same external URL keeps one id after title, date, and venue edits", () => {
  const registry = new IdentityRegistry();
  const id = registry.allocate("performance");
  registry.remember(officialURL, id);
  registry.updateDescriptor(id, {
    title: "Tokyo",
    localDate: "2026-04-01",
    venue: "Garden",
  });
  registry.updateDescriptor(id, {
    title: "Tokyo Final",
    localDate: "2026-04-02",
    venue: "Arena",
  });
  assert.equal(registry.lookup(officialURL), id);
  assert.equal(registry.descriptor(id)?.title, "Tokyo Final");
  assert.equal(registry.descriptor(id)?.localDate, "2026-04-02");
  assert.equal(registry.descriptor(id)?.venue, "Arena");
  assert.equal(registry.ids().length, 1);
});

test("title and date are not an id", () => {
  const registry = new IdentityRegistry();
  const first = registry.allocate("event");
  const second = registry.allocate("event");
  registry.updateDescriptor(first, {
    title: "Fest",
    localDate: "2026-01-02",
    venue: "Tokyo",
  });
  registry.updateDescriptor(second, {
    title: "Fest",
    localDate: "2026-01-02",
    venue: "Tokyo",
  });
  assert.notEqual(first, second);
  assert.equal(
    registry.lookupHint({ title: "Fest", localDate: "2026-01-02", index: 0 }),
    undefined,
  );
});

test("model-supplied id is ignored", () => {
  const registry = new IdentityRegistry();
  const id = registry.allocate("event");
  assert.notEqual(id, "event_from-model");
  assert.match(
    id,
    /^event_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
  );
  assert.equal(
    registry.lookupHint({
      modelId: "event_from-model",
      title: "Fest",
      localDate: "2026-01-02",
      index: 0,
    }),
    undefined,
  );
  registry.remember(officialURL, id);
  assert.equal(
    registry.lookupHint({
      externalKey: officialURL,
      modelId: "event_from-model",
      title: "Other",
      localDate: "1999-01-01",
      index: 3,
    }),
    id,
  );
  assert.throws(
    () =>
      registry.remember("https://official.example/other", "event_from-model"),
    /unknown id/,
  );
});

test("day and night are distinct performances; Tokyo and Osaka are distinct stops", () => {
  const registry = new IdentityRegistry();
  const day = registry.allocate("performance");
  const night = registry.allocate("performance");
  registry.remember(`${officialURL}#day`, day);
  registry.remember(`${officialURL}#night`, night);
  registry.updateDescriptor(day, {
    title: "Show",
    localDate: "2026-05-01",
    venue: "Hall",
  });
  registry.updateDescriptor(night, {
    title: "Show",
    localDate: "2026-05-01",
    venue: "Hall",
  });
  assert.notEqual(day, night);
  assert.equal(registry.kind(day), "performance");
  assert.equal(registry.kind(night), "performance");
  const tokyo = registry.allocate("stop");
  const osaka = registry.allocate("stop");
  registry.updateDescriptor(tokyo, { title: "Tokyo", venue: "Tokyo" });
  registry.updateDescriptor(osaka, { title: "Osaka", venue: "Osaka" });
  assert.notEqual(tokyo, osaka);
  assert.equal(registry.kind(tokyo), "stop");
  assert.equal(registry.kind(osaka), "stop");
});

test("goods session is not a performance", () => {
  const registry = new IdentityRegistry();
  const goods = registry.allocate("goodsSession");
  const performance = registry.allocate("performance");
  assert.match(goods, /^goodsSession_/);
  assert.match(performance, /^performance_/);
  assert.equal(registry.kind(goods), "goodsSession");
  assert.notEqual(registry.kind(goods), registry.kind(performance));
});

test("remap keeps external key and does not mint", () => {
  const registry = new IdentityRegistry();
  const fromId = registry.allocate("stop");
  const toId = registry.allocate("stop");
  const key = "https://official.example/tour#osaka";
  registry.remember(key, fromId);
  registry.remap(fromId, toId, "merged stop");
  assert.equal(registry.lookup(key), fromId);
  assert.deepEqual(registry.ids().sort(), [fromId, toId].sort());
  assert.deepEqual(registry.remaps(), [
    { fromId, toId, reason: "merged stop" },
  ]);
  assert.throws(() => registry.remember(key, toId), /already bound/);
});

test("unverified scope stays unconfirmed", () => {
  assert.deepEqual(
    materializeScope({
      statement: "event",
      performanceIDs: ["performance_tokyo", "performance_osaka"],
      verifiedPerformanceIDs: ["performance_tokyo"],
    }),
    { kind: "unconfirmed", reason: "unverified-performance" },
  );
  assert.deepEqual(
    materializeScope({
      statement: "performances",
      performanceIDs: [],
      verifiedPerformanceIDs: ["performance_tokyo"],
    }),
    { kind: "unconfirmed", reason: "no-performances" },
  );
  assert.deepEqual(
    materializeScope({
      statement: "stop",
      performanceIDs: ["performance_b", "performance_a", "performance_a"],
      verifiedPerformanceIDs: [
        "performance_b",
        "performance_a",
        "performance_extra",
      ],
    }),
    {
      kind: "performances",
      performanceIDs: ["performance_a", "performance_b"],
    },
  );
});

test("a new Osaka date does not inherit Tokyo ticket scope", () => {
  const tokyo = "performance_tokyo";
  const osaka = "performance_osaka";
  const inherited = inheritScope([tokyo], [tokyo, osaka]);
  assert.deepEqual(inherited, [tokyo]);
  assert.equal(inherited.includes(osaka), false);
});

test("missing local time is not 00:00", () => {
  const missing = { localDate: "2026-05-01", localTime: null };
  assert.equal(explicitLocalTime(missing, false), null);
  assert.notEqual(explicitLocalTime(missing, false), "00:00");
  assert.throws(
    () =>
      assertNoInventedInstant(
        { localDate: "2026-05-01", localTime: "00:00" },
        false,
      ),
    /00:00/,
  );
  assert.equal(
    explicitLocalTime({ localDate: "2026-05-01", localTime: "00:00" }, true),
    "00:00",
  );
});

test("deadline without timezone throws", () => {
  assert.throws(
    () =>
      ticketDeadline({
        localDate: "2026-05-01",
        localTime: "23:59",
        timeZone: undefined,
      }),
    /timezone required/,
  );
  assert.throws(
    () =>
      ticketDeadline({
        localDate: "2026-05-01",
        localTime: "23:59",
        timeZone: null,
      }),
    /timezone required/,
  );
  assert.deepEqual(
    ticketDeadline({
      localDate: "2026-05-01",
      localTime: "23:59",
      timeZone: "Asia/Tokyo",
    }),
    {
      localDate: "2026-05-01",
      localTime: "23:59",
      timeZone: "Asia/Tokyo",
    },
  );
});
