import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import * as cheerio from "cheerio";
import {
  makeSnapshot,
  parseJapaneseDateTimeWindow,
  parseJapaneseSchedules,
  parseSnapshot,
} from "../src/ingestion/index.js";

const fixtureRoot = path.resolve("tests/fixtures/snapshots");

async function fixture(name: string, url: string) {
  const body = await readFile(path.join(fixtureRoot, name));
  return makeSnapshot({
    sourceDocumentId: name,
    fetchUrl: url,
    finalUrl: url,
    statusCode: 200,
    headers: { "content-type": "text/html" },
    fetchedAt: "2026-09-22T00:00:00.000Z",
    body,
  });
}

async function researchFixture(name: string, url: string) {
  const body = await readFile(path.resolve("tests/fixtures/research", name));
  return makeSnapshot({
    sourceDocumentId: name,
    fetchUrl: url,
    finalUrl: url,
    statusCode: 200,
    headers: { "content-type": "text/html" },
    fetchedAt: "2026-09-22T18:00:00.000Z",
    body,
  });
}

test("BanG Dream index discovers only real event cards", async () => {
  const result = parseSnapshot(
    await fixture(
      "bangdream_events_index.html",
      "https://bang-dream.com/events/",
    ),
  );
  assert.equal(result.adapterId, "bangdream.event-index");
  assert.ok(result.links.length >= 10);
  assert.ok(
    result.links.every(
      (link) =>
        new URL(link.url).hostname === "bang-dream.com" &&
        link.role === "event",
    ),
  );
  assert.ok(
    result.candidates.some(
      (candidate) => candidate.field === "event.officialTitle",
    ),
  );
});

test("BanG Dream detail extracts bounded semantic sections with evidence", async () => {
  const snapshot = await fixture(
    "bangdream_event_mygo_avemujica2026.html",
    "https://bang-dream.com/events/mygo-avemujica2026/",
  );
  const result = parseSnapshot(snapshot, {
    entityRef: { eventId: "caller-event-uuid" },
  });
  assert.equal(result.adapterId, "bangdream.event-detail");
  assert.ok(
    result.candidates.some(
      (candidate) =>
        candidate.field === "event.officialTitle" &&
        candidate.entityRef.eventId === "caller-event-uuid",
    ),
  );
  assert.ok(
    result.candidates.some(
      (candidate) => candidate.field === "performance.scheduleRaw",
    ),
  );
  assert.ok(
    result.candidates.every(
      (candidate) =>
        candidate.sourceSnapshotId === snapshot.id &&
        candidate.evidence.rawText.length > 0,
    ),
  );
});

test("BanG Dream 13th hub emits three independently keyed official day schedules", async () => {
  const result = parseSnapshot(
    await fixture(
      "bangdream_13th_live_hub.html",
      "https://bang-dream.com/13th-live/",
    ),
  );
  const schedules = result.candidates.filter(
    (candidate) => candidate.field === "performance.schedule",
  );
  assert.equal(schedules.length, 3);
  assert.deepEqual(
    schedules.map(
      (candidate) => (candidate.value as { dayLabel: string }).dayLabel,
    ),
    ["DAY1", "DAY2", "DAY3"],
  );
  assert.deepEqual(
    schedules.map(
      (candidate) => (candidate.value as { localDate: string }).localDate,
    ),
    ["2026-10-10", "2026-10-11", "2026-10-12"],
  );
  assert.ok(
    schedules.every((candidate) =>
      candidate.entityRef.sourceKey?.includes("#performance:DAY"),
    ),
  );
  assert.equal(
    result.candidates.filter(
      (candidate) => candidate.field === "performance.performers",
    ).length,
    3,
  );
});

test("each BanG Dream 13th day detail keeps its own schedule, ticket tiers, rounds, and goods evidence", async () => {
  for (const day of [1, 2, 3]) {
    const performanceId = `day-${day}-uuid`;
    const result = parseSnapshot(
      await fixture(
        `bangdream_13th_live_day${day}.html`,
        `https://bang-dream.com/events/13th-live-day${day}/`,
      ),
      { performanceRefs: { [`DAY${day}`]: performanceId } },
    );
    const schedules = result.candidates.filter(
      (candidate) => candidate.field === "performance.schedule",
    );
    assert.equal(schedules.length, 1);
    assert.equal(
      (schedules[0]!.value as { dayLabel: string }).dayLabel,
      `DAY${day}`,
    );
    assert.ok(
      result.candidates.some((candidate) => candidate.field === "ticket.tiers"),
    );
    const general = result.candidates.find(
      (candidate) =>
        candidate.field === "ticket.round" &&
        (candidate.value as { officialName?: string }).officialName ===
          "一般発売",
    );
    assert.equal(
      (general?.value as { dayLabel?: string }).dayLabel,
      `DAY${day}`,
    );
    assert.deepEqual(general?.applicability, {
      kind: "performances",
      performanceIds: [performanceId],
    });
    const goods = result.candidates.find(
      (candidate) => candidate.field === "goods.campaign",
    );
    assert.equal(
      (goods?.value as { salesStartAt?: string }).salesStartAt,
      "2026-09-11T15:00:00+09:00",
    );
    assert.match(
      (goods?.value as { url: string }).url,
      new RegExp(`day${day}`, "i"),
    );
    assert.deepEqual(goods?.applicability, {
      kind: "performances",
      performanceIds: [performanceId],
    });
  }
});

test("captured BD02-BD10 pages remain classified as verified BanG Dream details", async () => {
  const pages = [
    [
      "BD02.html",
      "https://bang-dream.com/events/mygo_9th/",
      "MyGO!!!!! 9th LIVE",
    ],
    [
      "BD03.html",
      "https://bang-dream.com/events/morfonica_live_2026/",
      "Morfonica LIVE「Movement」",
    ],
    [
      "BD04.html",
      "https://bang-dream.com/events/eleganza/",
      "Morfonica LIVE「eleganza」",
    ],
    [
      "BD05.html",
      "https://bang-dream.com/events/roselia-10th-anniversary-live-tour/",
      "Roselia 10th Anniversary LIVE TOUR",
    ],
    [
      "BD06.html",
      "https://bang-dream.com/events/lehre-der-rose/",
      "Roselia「Lehre der Rose」",
    ],
    [
      "BD07.html",
      "https://bang-dream.com/avemujica_livetour_final/",
      "Ave Mujica LIVE TOUR 2026「Exitus」-FINAL-",
    ],
    [
      "BD08.html",
      "https://bang-dream.com/ras_2026_tokyo/",
      "RAISE A SUILEN LIVE 2026「Boot IGNITION」東京公演",
    ],
    [
      "BD09.html",
      "https://bang-dream.com/yumemita_superposition/",
      "夢限大みゅーたいぷ 47都道府県制覇の旅「スーパーポジション」",
    ],
    [
      "BD10.html",
      "https://bang-dream.com/events/ppp-roselia2026/",
      "Poppin'Party×Roselia 合同ライブ「DREAMS GO ON」",
    ],
  ] as const;
  for (const [name, url, title] of pages) {
    const result = parseSnapshot(await researchFixture(name, url));
    assert.equal(result.adapterId, "bangdream.event-detail", name);
    assert.ok(
      result.candidates.some(
        (candidate) =>
          candidate.field === "event.officialTitle" &&
          typeof candidate.value === "string" &&
          candidate.value.includes(title),
      ),
      name,
    );
    assert.equal(
      result.issues.some((issue) => issue.code === "unknown_template"),
      false,
      name,
    );
  }
});

test("captured BanG Dream pages expose only the bounded primary schedules and venues", async () => {
  const expected = [
    [
      "BD02.html",
      "https://bang-dream.com/events/mygo_9th/",
      ["2026-07-18", "2026-07-19"],
      ["ぴあアリーナMM"],
    ],
    [
      "BD03.html",
      "https://bang-dream.com/events/morfonica_live_2026/",
      ["2026-09-22"],
      ["TACHIKAWA STAGE GARDEN"],
    ],
    [
      "BD04.html",
      "https://bang-dream.com/events/eleganza/",
      ["2027-01-09"],
      ["Kanadevia Hall"],
    ],
    [
      "BD05.html",
      "https://bang-dream.com/events/roselia-10th-anniversary-live-tour/",
      ["2027-01-30", "2027-02-28", "2027-03-14", "2027-04-25"],
      [
        "TOYOTA ARENA TOKYO",
        "愛知県芸術劇場 大ホール",
        "仙台サンプラザホール",
        "福岡サンパレス",
      ],
    ],
    [
      "BD06.html",
      "https://bang-dream.com/events/lehre-der-rose/",
      ["2026-08-29", "2026-08-30"],
      ["有明アリーナ"],
    ],
    [
      "BD07.html",
      "https://bang-dream.com/avemujica_livetour_final/",
      ["2026-06-19", "2026-06-20"],
      ["SGC HALL ARIAKE"],
    ],
    [
      "BD08.html",
      "https://bang-dream.com/ras_2026_tokyo/",
      ["2026-06-18"],
      ["SGC HALL ARIAKE"],
    ],
    ["BD09.html", "https://bang-dream.com/yumemita_superposition/", [], []],
    [
      "BD10.html",
      "https://bang-dream.com/events/ppp-roselia2026/",
      ["2026-05-03"],
      ["有明アリーナ"],
    ],
  ] as const;
  for (const [name, url, dates, venues] of expected) {
    const result = parseSnapshot(await researchFixture(name, url));
    assert.deepEqual(
      result.candidates
        .filter((candidate) => candidate.field === "performance.schedule")
        .map(
          (candidate) => (candidate.value as { localDate: string }).localDate,
        ),
      dates,
      name,
    );
    assert.deepEqual(
      result.candidates
        .filter((candidate) => candidate.field === "performance.venueRaw")
        .map((candidate) => candidate.value),
      venues,
      name,
    );
  }
});

test("e+ detail keeps all seven ticket rounds inside their explicit DAY article", async () => {
  const result = parseSnapshot(
    await researchFixture(
      "BD01-eplus.html",
      "https://eplus.jp/sf/detail/4529430001",
    ),
    { performanceRefs: { DAY1: "day-1", DAY2: "day-2", DAY3: "day-3" } },
  );
  assert.equal(result.adapterId, "eplus.event-detail");
  const rounds = result.candidates.filter(
    (candidate) => candidate.field === "ticket.round",
  );
  assert.deepEqual(
    rounds.map(
      (candidate) => (candidate.value as { dayLabel: string }).dayLabel,
    ),
    ["DAY1", "DAY1", "DAY1", "DAY2", "DAY2", "DAY3", "DAY3"],
  );
  assert.ok(
    rounds.every(
      (candidate) =>
        candidate.entityRef.performanceId ===
        `day-${(candidate.value as { dayLabel: string }).dayLabel.slice(-1)}`,
    ),
  );
  assert.ok(
    rounds.every(
      (candidate) =>
        candidate.applicability.kind === "performances" &&
        candidate.applicability.performanceIds?.[0] ===
          candidate.entityRef.performanceId,
    ),
  );
  assert.deepEqual(
    rounds
      .slice(0, 3)
      .map(
        (candidate) =>
          (candidate.value as { applyStartAt: string }).applyStartAt,
      ),
    [
      "2026-09-19T12:00:00+09:00",
      "2026-07-24T18:00:00+09:00",
      "2026-08-28T17:00:00+09:00",
    ],
  );
});

test("Love Live branch discovery preserves p and _id semantic parameters", async () => {
  const lovehigh = parseSnapshot(
    await fixture(
      "lovelive_lovehigh_live.html",
      "https://www.lovelive-anime.jp/lovehigh/live/",
    ),
  );
  assert.equal(lovehigh.adapterId, "lovelive.branch-index");
  assert.ok(lovehigh.links.some((link) => link.url.includes("?_id=3rdLIVE")));
  assert.ok(
    lovehigh.links.some((link) => link.url.includes("?p=15th_lovelivefest")),
  );
});

test("Love Live detail produces structured schedules, ticket tiers, and scoped media", async () => {
  const snapshot = await fixture(
    "lovelive_detail_15th_lovelivefest.html",
    "https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest",
  );
  const result = parseSnapshot(snapshot, {
    entityRef: { eventId: "event-uuid" },
    performanceRefs: { "Day.1": "day-1-uuid", "Day.2": "day-2-uuid" },
  });
  assert.equal(result.adapterId, "lovelive.live-detail");
  assert.ok(
    result.candidates.some(
      (candidate) => candidate.field === "performance.schedule",
    ),
  );
  assert.ok(
    result.candidates.some((candidate) => candidate.field === "ticket.tiers"),
  );
  assert.ok(
    result.media.some((candidate) => candidate.purpose === "event_seating_map"),
  );
  const searchable = normalizeEvidence(cheerio.load(snapshot.text).text());
  assert.ok(
    result.media.every((candidate) =>
      searchable.includes(normalizeEvidence(candidate.evidence.rawText)),
    ),
  );
  assert.ok(result.links.some((link) => link.role === "goods"));
  const rounds = result.candidates.filter(
    (candidate) => candidate.field === "ticket.round",
  );
  assert.equal(rounds.length, 10);
  const general = rounds.find(
    (candidate) =>
      (candidate.value as { officialName: string }).officialName ===
      "一般発売（抽選）",
  );
  assert.deepEqual(general?.value, {
    officialName: "一般発売（抽選）",
    kind: "lottery",
    applyStartAt: "2026-09-05T12:00:00+09:00",
    applyEndAt: "2026-09-27T23:59:00+09:00",
    resultAt: "2026-10-03T13:00:00+09:00",
    paymentDeadlineAt: "2026-10-06T21:00:00+09:00",
    applyURL: "https://eplus.jp/ll15th/",
    windowRaw: "2026年9月5日(土)12:00~9月27日(日)23:59",
  });
  const cast = result.candidates.filter(
    (candidate) => candidate.field === "performance.cast",
  );
  assert.equal(cast.length, 8);
  assert.deepEqual(cast[0]!.value, {
    group: "『ラブライブ！』 μ'ｓ",
    role: "on_stage",
    performers: [
      "新田恵海（高坂穂乃果役）",
      "内田 彩（南 ことり役）",
      "飯田里穂（星空 凛役）",
      "Pile（西木野真姫役）",
      "久保ユリカ（小泉花陽役）",
      "徳井青空（矢澤にこ役）",
    ],
  });
  assert.ok(
    cast.some(
      (candidate) =>
        (candidate.value as { role: string; performers: string[] }).role ===
          "support" &&
        (candidate.value as { performers: string[] }).performers[0] ===
          "矢野妃菜喜（高咲 侑役）",
    ),
  );
  assert.ok(
    cast.every((candidate) => candidate.applicability.kind === "unresolved"),
  );
  const goods = result.candidates.find(
    (candidate) => candidate.field === "goods.campaign",
  );
  assert.equal(
    (goods?.value as { salesStartAt?: string }).salesStartAt,
    "2026-07-03T18:00:00+09:00",
  );
  assert.equal(
    (goods?.value as { salesEndAt?: string }).salesEndAt,
    "2026-08-02T23:59:00+09:00",
  );
  const upgrades = rounds.filter((candidate) =>
    (candidate.value as { officialName: string }).officialName.startsWith(
      "アップグレード受付",
    ),
  );
  assert.equal(upgrades.length, 2);
  assert.equal(
    new Set(upgrades.map((candidate) => candidate.evidence.locator)).size,
    2,
  );
  assert.equal(
    new Set(upgrades.map((candidate) => candidate.entityRef.sourceKey)).size,
    2,
  );
});

test("captured Bushiroad campaign pages emit linked products, prices, and distinct happi timing", async () => {
  const day1 = parseSnapshot(
    await researchFixture(
      "BD01-goods-day1.html",
      "https://bushiroad-store.com/pages/bd_13th-live-day1-poppinparty",
    ),
  );
  assert.equal(day1.adapterId, "goods.bushiroad-page");
  const campaigns = day1.candidates.filter(
    (candidate) => candidate.field === "goods.campaign",
  );
  assert.deepEqual(
    campaigns.map(
      (candidate) => (candidate.value as { salesStartAt: string }).salesStartAt,
    ),
    ["2026-09-11T15:00:00+09:00", "2026-09-11T17:00:00+09:00"],
  );
  assert.deepEqual(
    campaigns.map(
      (candidate) => (candidate.value as { shippingNote: string }).shippingNote,
    ),
    ["2026年10月3日(土)ごろ", "2026年10月8日(木)ごろ"],
  );
  assert.ok(
    campaigns.every(
      (candidate) => !("requiresTicket" in (candidate.value as object)),
    ),
  );
  const products = day1.candidates.filter(
    (candidate) => candidate.field === "goods.product",
  );
  assert.equal(products.length, 84);
  assert.deepEqual((products[0]!.value as { amount: unknown }).amount, {
    minorUnits: 4400,
    currency: "JPY",
  });
  const happi = products.find((candidate) =>
    /法被/.test((candidate.value as { name: string }).name),
  );
  assert.match(
    (happi?.value as { campaignSourceKey: string }).campaignSourceKey,
    /#campaign:happi$/,
  );
  assert.ok(day1.media.every((candidate) => candidate.purpose === "product"));
  assertPriceEvidence(products);

  const exitus = parseSnapshot(
    await researchFixture(
      "BD07-goods-exitus.html",
      "https://bushiroad-store.com/pages/avemujica_livetour-2026",
    ),
  );
  const exitusCampaign = exitus.candidates.find(
    (candidate) => candidate.field === "goods.campaign",
  );
  assert.equal(
    (exitusCampaign?.value as { salesStartAt: string }).salesStartAt,
    "2026-06-05T15:00:00+09:00",
  );
  const exitusProducts = exitus.candidates.filter(
    (candidate) => candidate.field === "goods.product",
  );
  assert.equal(exitusProducts.length, 85);
  assert.deepEqual(
    (exitusProducts[0]!.value as { amount: unknown; stockStatus: string })
      .amount,
    { minorUnits: 1650, currency: "JPY" },
  );
  assert.equal(
    (exitusProducts[0]!.value as { stockStatus: string }).stockStatus,
    "available",
  );
  assertPriceEvidence(exitusProducts);
});

test("captured School idol STORE pages emit exact campaigns, products, and priced variants", async () => {
  const pages = [
    [
      "LL03-goods.html",
      "https://lovelive.fannect.jp/collections/ll-48-01",
      "2026-08-28T18:00:00+09:00",
      "2026-09-07T23:59:00+09:00",
      "pre_event",
      13,
    ],
    [
      "LL08-goods.html",
      "https://lovelive.fannect.jp/collections/ll-47-01",
      "2026-06-22T18:00:00+09:00",
      "2026-07-24T23:59:00+09:00",
      "pre_event",
      11,
    ],
    [
      "LL10-goods.html",
      "https://lovelive.fannect.jp/collections/ll-43-03",
      "2026-07-14T18:00:00+09:00",
      "2026-07-20T23:59:00+09:00",
      "post_event",
      19,
    ],
  ] as const;
  for (const [name, url, start, end, phase, count] of pages) {
    const result = parseSnapshot(await researchFixture(name, url));
    assert.equal(result.adapterId, "goods.school-idol-store", name);
    const campaign = result.candidates.find(
      (candidate) => candidate.field === "goods.campaign",
    );
    assert.equal(
      (campaign?.value as { salesStartAt: string }).salesStartAt,
      start,
      name,
    );
    assert.equal(
      (campaign?.value as { salesEndAt: string }).salesEndAt,
      end,
      name,
    );
    assert.equal((campaign?.value as { phase: string }).phase, phase, name);
    const products = result.candidates.filter(
      (candidate) => candidate.field === "goods.product",
    );
    assert.equal(products.length, count, name);
    const shirt = products.find((candidate) =>
      (candidate.value as { name: string }).name.startsWith("Tシャツ"),
    );
    const variants = (
      shirt?.value as {
        variants: { amount: { minorUnits: number; currency: string } }[];
      }
    ).variants;
    assert.equal(variants.length, 3, name);
    assert.ok(
      variants.every((variant) => !("stockStatus" in variant)),
      "Product-level status must not become variant stock",
    );
    assert.ok(
      variants.every(
        (variant) =>
          variant.amount.minorUnits === 3500 &&
          variant.amount.currency === "JPY",
      ),
      name,
    );
    assert.equal(
      (shirt?.value as { campaignSourceKey: string }).campaignSourceKey,
      (campaign?.value as { sourceKey: string }).sourceKey,
      name,
    );
    assert.ok(
      result.media.every((candidate) => candidate.purpose === "product"),
      name,
    );
    assertPriceEvidence(products);
  }
});

test("captured after-pamphlet product exposes its post-event window, limit, and visible price", async () => {
  const result = parseSnapshot(
    await researchFixture(
      "LL01-after-pamphlet.html",
      "https://lovelive.fannect.jp/products/lamd84829",
    ),
  );
  const campaign = result.candidates.find(
    (candidate) => candidate.field === "goods.campaign",
  );
  assert.deepEqual(campaign?.value, {
    sourceKey: "lovelive.fannect.jp/products/lamd84829#campaign",
    officialName: "アフターパンフレット",
    channel: "online",
    fulfillment: "shipping",
    phase: "post_event",
    salesStartAt: "2026-07-03T18:00:00+09:00",
    salesEndAt: "2026-11-30T23:59:00+09:00",
    shippingNote: "2027年6月以降のお届け予定です",
    url: "https://lovelive.fannect.jp/products/lamd84829",
    windowRaw: "7月3日(金)18:00～11月30日(月)23:59まで",
  });
  const product = result.candidates.find(
    (candidate) => candidate.field === "goods.product",
  )!;
  assert.deepEqual((product.value as { amount: unknown }).amount, {
    minorUnits: 8000,
    currency: "JPY",
  });
  assert.equal(
    (product.value as { purchaseLimit: string }).purchaseLimit,
    "1会計につき2点まで",
  );
  assert.equal(
    (product.value as { campaignSourceKey: string }).campaignSourceKey,
    (campaign?.value as { sourceKey: string }).sourceKey,
  );
  assertPriceEvidence([product]);
});

test("captured venue page supplies the exact single performance and six ticket tiers", async () => {
  const result = parseSnapshot(
    await researchFixture(
      "BD03-venue.html",
      "https://www.t-sg.jp/events/2026/09/00001502.php",
    ),
  );
  assert.equal(result.adapterId, "venue.tachikawa-event");
  const schedule = result.candidates.find(
    (candidate) => candidate.field === "performance.schedule",
  );
  assert.deepEqual(schedule?.value, {
    localDate: "2026-09-22",
    doorsAt: "17:00",
    startsAt: "18:00",
    timeZone: "Asia/Tokyo",
    raw: "2026年9月22日(火) 17:00開場/18:00開演",
    dayLabel: "single",
  });
  assert.ok(
    result.candidates.some(
      (candidate) =>
        candidate.field === "performance.venueRaw" &&
        candidate.value === "TACHIKAWA STAGE GARDEN",
    ),
  );
  const tiers = result.candidates.find(
    (candidate) => candidate.field === "ticket.tiers",
  )?.value as unknown[];
  assert.equal(tiers.length, 6);
});

test("BD08 and BD10 ancillary blocks remain isolated to their explicit stream, resale, qualification, and venue sections", async () => {
  const bd08 = parseSnapshot(
    await researchFixture(
      "BD08.html",
      "https://bang-dream.com/ras_2026_tokyo/",
    ),
  );
  const stream = bd08.candidates.find(
    (candidate) => candidate.field === "stream.offer",
  );
  assert.deepEqual(stream?.value, {
    officialName: "配信チケット / Ticket for overseas",
    platform: "eplus",
    amount: { minorUnits: 5500, currency: "JPY" },
    salesStartAt: "2026-06-09T18:00:00+09:00",
    salesEndAt: "2026-06-25T21:00:00+09:00",
    archiveAvailableUntil: "2026-06-25T23:59:00+09:00",
    url: "https://eplus.jp/ras-2026/st/",
    overseasURL: "https://ib.eplus.jp/ras-2026_st",
  });
  assert.match(stream!.evidence.rawText, /5,500円/);
  const resale08 = bd08.candidates.find(
    (candidate) => candidate.field === "ticket.resale",
  );
  assert.equal(
    (resale08?.value as { applyStartAt: string }).applyStartAt,
    "2026-06-08T12:00:00+09:00",
  );
  assert.equal(
    (resale08?.value as { applyEndAt: string }).applyEndAt,
    "2026-06-14T11:59:00+09:00",
  );
  assert.match(
    String(
      bd08.candidates.find(
        (candidate) => candidate.field === "ticket.qualificationRaw",
      )?.value,
    ),
    /公的な顔写真付身分証明書1点/,
  );
  assert.deepEqual(
    bd08.candidates
      .filter((candidate) => candidate.field === "goods.session")
      .map(
        (candidate) =>
          (candidate.value as { startsAt: string; endsAt: string }).startsAt,
      ),
    ["2026-06-18T12:30:00+09:00", "2026-06-18T17:30:00+09:00"],
  );

  const bd10 = parseSnapshot(
    await researchFixture(
      "BD10.html",
      "https://bang-dream.com/events/ppp-roselia2026/",
    ),
  );
  const resale10 = bd10.candidates.find(
    (candidate) => candidate.field === "ticket.resale",
  );
  assert.equal(
    (resale10?.value as { applyStartAt: string }).applyStartAt,
    "2026-04-23T12:00:00+09:00",
  );
  assert.equal(
    (resale10?.value as { applyEndAt: string }).applyEndAt,
    "2026-04-29T11:59:00+09:00",
  );
  assert.match(
    String(
      bd10.candidates.find(
        (candidate) => candidate.field === "ticket.qualificationRaw",
      )?.value,
    ),
    /身分証をご提示いただけない場合/,
  );
  const venueCampaigns = bd10.candidates.filter(
    (candidate) =>
      candidate.field === "goods.campaign" &&
      (candidate.value as { channel?: string }).channel === "venue",
  );
  assert.equal(venueCampaigns.length, 2);
  assert.ok(
    venueCampaigns.every(
      (candidate) =>
        (candidate.value as { requiresTicket?: boolean }).requiresTicket ===
        false,
    ),
  );
  assert.equal(
    bd10.candidates.filter((candidate) => candidate.field === "goods.session")
      .length,
    2,
  );
  assert.equal(
    bd10.candidates.some(
      (candidate) =>
        candidate.field === "goods.campaign" &&
        (candidate.value as { officialName?: string }).officialName ===
          "販売日時",
    ),
    false,
  );
});

test("numeric date parsing rejects invalid calendar dates and normalizes 24:00", () => {
  assert.deepEqual(
    parseJapaneseSchedules("DAY1：2026年2月30日 18:00開場／19:00開演"),
    [],
  );
  assert.deepEqual(
    parseJapaneseDateTimeWindow(
      "受付期間：2026年10月12日24:00～2026年10月13日24:01",
      "受付期間",
    ),
    {
      startAt: "2026-10-13T00:00:00+09:00",
      raw: "2026年10月12日24:00~2026年10月13日24:01",
    },
  );
});

test("empty Bushiroad redirect articles stay explicit and do not fabricate campaigns", async () => {
  const result = parseSnapshot(
    await fixture(
      "bushiroad_goods_bangdream13th_day1.html",
      "https://bushiroad-store.com/blogs/live/bang-dream-13th-live-day1-poppinparty-now-roading-%E3%82%B0%E3%83%83%E3%82%BA%E9%80%9A%E8%B2%A9",
    ),
  );
  assert.equal(result.adapterId, "goods.bushiroad-live-article");
  assert.ok(result.issues.some((issue) => issue.code === "redirect_shell"));
  assert.ok(result.links.some((link) => link.role === "redirect"));
  assert.equal(
    result.candidates.some(
      (candidate) => candidate.field === "goods.campaignRaw",
    ),
    false,
  );
});

test("unknown templates fail explicitly", () => {
  const snapshot = makeSnapshot({
    sourceDocumentId: "unknown",
    fetchUrl: "https://example.com/",
    finalUrl: "https://example.com/",
    statusCode: 200,
    headers: { "content-type": "text/html" },
    body: Buffer.from("<!doctype html><html><main>unknown</main></html>"),
  });
  const result = parseSnapshot(snapshot);
  assert.deepEqual(result.candidates, []);
  assert.equal(result.issues[0]?.code, "unknown_template");
});

function normalizeEvidence(value: string): string {
  return value.normalize("NFKC").replace(/\s+/g, " ").trim();
}

function assertPriceEvidence(
  products: readonly { value: unknown; evidence: { rawText: string } }[],
): void {
  for (const product of products) {
    const value = product.value as {
      amount?: { minorUnits: number };
      variants?: { amount?: { minorUnits: number } }[];
    };
    const evidence = normalizeEvidence(product.evidence.rawText).replaceAll(
      ",",
      "",
    );
    if (value.amount)
      assert.ok(evidence.includes(String(value.amount.minorUnits)));
    for (const variant of value.variants ?? [])
      if (variant.amount)
        assert.ok(evidence.includes(String(variant.amount.minorUnits)));
  }
}
