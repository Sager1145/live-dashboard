import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);

const compact = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
const performerKey = (value) => compact(value)
  .replace(/^[・●]\s*/, "")
  .replace(/^ゲスト[:：]\s*/, "")
  .replace(/[（(](?:オープニングアクト|ゲスト|夢限大みゅーたいぷ)[^）)]*[）)]/g, "")
  .trim();
const performerAppears = (actual, expected) => {
  const wanted = performerKey(expected);
  return actual.some((value) => performerKey(value).includes(wanted));
};
const venueMatches = (actual, expected) => {
  const got = compact(actual);
  const want = compact(expected);
  if (got === want) return true;
  const harmlessTail = (longer, shorter) => {
    if (!longer.startsWith(shorter)) return false;
    const tail = longer.slice(shorter.length).trim();
    return /^(?:（[^）]+）|\([^\)]+\))$/.test(tail);
  };
  return harmlessTail(got, want) || harmlessTail(want, got);
};
const canonicalImageURL = (value) => value.replace(/-\d+x\d+(?=\.[a-z0-9]+(?:\?.*)?$)/i, "");
const localTime = (iso, timeZone) => {
  if (!iso) return null;
  return new Intl.DateTimeFormat("en-GB", {
    timeZone,
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(iso));
};

const scopeKey = (scope) => {
  if (!scope) return null;
  const ids = [...(scope.performanceIDs ?? [])].sort();
  return `${scope.kind ?? ""}|${ids.join(",")}`;
};

export function compareRecords(expectedRecords, appRows) {
  const appByID = new Map(appRows.map((item) => [item.id, item.bundle]));
  const result = [];
  for (const record of expectedRecords) {
    const id = `bangdream-${record.wordpressID}`;
  const bundle = appByID.get(id);
  const mismatches = [];
  if (!bundle) {
    result.push({ id, rank: record.publicationRank, mismatches: [{ field: "record", expected: "present", actual: "missing" }] });
    continue;
  }
  if (bundle.event.officialTitle !== record.officialTitle) {
    mismatches.push({ field: "title", expected: record.officialTitle, actual: bundle.event.officialTitle });
  }
  if (record.status != null && bundle.event.status !== record.status) {
    mismatches.push({ severity: "material", field: "event.status", expected: record.status, actual: bundle.event.status });
  }
  const actualPerformances = bundle.performances ?? [];
  if (actualPerformances.length !== record.expectedPerformanceCount) {
    mismatches.push({ field: "performanceCount", expected: record.expectedPerformanceCount, actual: actualPerformances.length });
  }
  record.performances.forEach((want, index) => {
    const got = actualPerformances[index];
    if (!got) return;
    for (const field of ["localDate", "venue"]) {
      if (want[field] == null) continue;
      const actual = field === "venue" ? got.venueName : got[field];
      const matches = field === "venue" ? venueMatches(actual, want[field]) : compact(actual) === compact(want[field]);
      if (!matches) mismatches.push({ severity: "material", field: `performances[${index}].${field}`, expected: want[field], actual });
    }
    if (want.timeZone && got.timeZone !== want.timeZone) {
      mismatches.push({ severity: "material", field: `performances[${index}].timeZone`, expected: want.timeZone, actual: got.timeZone });
    }
    if (want.venueCity != null && compact(got.venueCity) !== compact(want.venueCity)) {
      mismatches.push({ severity: "material", field: `performances[${index}].venueCity`, expected: want.venueCity, actual: got.venueCity ?? "" });
    }
    if (want.doorsLocal) {
      const actual = localTime(got.doorsAt, want.timeZone);
      if (actual !== want.doorsLocal) mismatches.push({ severity: "material", field: `performances[${index}].doorsLocal`, expected: want.doorsLocal, actual });
    }
    if (want.startLocal) {
      const actual = localTime(got.startAt, want.timeZone);
      if (actual !== want.startLocal) mismatches.push({ severity: "material", field: `performances[${index}].startLocal`, expected: want.startLocal, actual });
    }
    const actualPerformers = got.performers ?? [];
    const missingPerformers = want.performers.filter((name) => !performerAppears(actualPerformers, name));
    const prohibitedPerformers = (want.excludedPerformers ?? []).filter((name) => performerAppears(actualPerformers, name));
    if (missingPerformers.length) {
      mismatches.push({ severity: "material", field: `performances[${index}].missingPerformers`, expected: want.performers, actual: actualPerformers });
    }
    if (prohibitedPerformers.length) {
      mismatches.push({ severity: "material", field: `performances[${index}].wrongDayPerformers`, expectedAbsent: prohibitedPerformers, actual: actualPerformers });
    }
  });
  const tierKey = (tier) => `${compact(tier.name).replaceAll("（", "(").replaceAll("）", ")")}|${tier.amount?.minorUnits ?? tier.amountMinorUnits}|${tier.amount?.currency ?? tier.currency}`;
  const wantedTiers = record.ticketTiers.map(tierKey).sort();
  const actualTiers = (bundle.ticketTiers ?? []).map(tierKey).sort();
  if (JSON.stringify(wantedTiers) !== JSON.stringify(actualTiers)) {
    mismatches.push({ severity: "material", field: "ticketTiers", expected: wantedTiers, actual: actualTiers });
  }
  const wantedGoods = record.eventGoodsImages.map((image) => canonicalImageURL(image.url)).sort();
  const actualGoods = (bundle.mediaAssets ?? [])
    .filter((asset) => asset.kind === "goodsList")
    .map((asset) => canonicalImageURL(asset.originalURL))
    .sort();
  if (JSON.stringify(wantedGoods) !== JSON.stringify(actualGoods)) {
    mismatches.push({ severity: "material", field: "goodsImageURLs", expected: wantedGoods, actual: actualGoods });
  }
  if (Array.isArray(record.ticketRounds)) {
    for (const want of record.ticketRounds) {
      const got = (bundle.ticketRounds ?? []).find((round) => round.officialName === want.officialName);
      const label = `ticketRounds[${want.officialName}]`;
      if (!got) {
        mismatches.push({ severity: "material", field: label, expected: want.officialName, actual: "missing" });
        continue;
      }
      for (const field of ["applyStartAt", "applyEndAt", "paymentDeadlineAt"]) {
        if (want[field] == null) continue;
        if (got[field] !== want[field]) mismatches.push({ severity: "material", field: `${label}.${field}`, expected: want[field], actual: got[field] ?? null });
      }
      if (want.scope && scopeKey(got.scope) !== scopeKey(want.scope)) {
        mismatches.push({ severity: "material", field: `${label}.scope`, expected: want.scope, actual: got.scope ?? null });
      }
    }
  }
  if (Array.isArray(record.streamOffers)) {
    for (const want of record.streamOffers) {
      const got = (bundle.streamOffers ?? []).find((offer) => offer.officialName === want.officialName);
      const label = `streamOffers[${want.officialName}]`;
      if (!got) {
        mismatches.push({ severity: "material", field: label, expected: want.officialName, actual: "missing" });
        continue;
      }
      for (const field of ["salesStartAt", "salesEndAt", "archiveAvailableUntil"]) {
        if (want[field] == null) continue;
        if (got[field] !== want[field]) mismatches.push({ severity: "material", field: `${label}.${field}`, expected: want[field], actual: got[field] ?? null });
      }
      if (want.scope && scopeKey(got.scope) !== scopeKey(want.scope)) {
        mismatches.push({ severity: "material", field: `${label}.scope`, expected: want.scope, actual: got.scope ?? null });
      }
    }
  }
  result.push({ id, rank: record.publicationRank, title: record.officialTitle, mismatches });
}
  return result;
}

if (process.argv[2] === "--self-test") {
  const base = {
    wordpressID: "1",
    publicationRank: 1,
    officialTitle: "Sample",
    expectedPerformanceCount: 1,
    performances: [{ localDate: "2027-01-09", venue: "Kanadevia Hall", performers: ["Morfonica"] }],
    ticketTiers: [],
    eventGoodsImages: [],
  };
  const app = [{
    id: "bangdream-1",
    bundle: {
      event: { officialTitle: "Sample", status: "scheduled" },
      performances: [{ localDate: "2027-01-09", venueName: "Kanadevia Hall", venueCity: "大阪", performers: ["Morfonica"], timeZone: "Asia/Tokyo" }],
      ticketTiers: [],
      mediaAssets: [],
      ticketRounds: [],
      streamOffers: [],
    },
  }];
  const skipped = compareRecords([base], app);
  if (skipped[0].mismatches.length !== 0) {
    console.error("optional keys must be skipped when the expected record omits them");
    process.exit(1);
  }
  const checked = compareRecords([{ ...base, performances: [{ ...base.performances[0], venueCity: "東京" }] }], app);
  if (!checked[0].mismatches.some((item) => item.field === "performances[0].venueCity")) {
    console.error("venueCity must be compared when the expected record has it");
    process.exit(1);
  }
  console.log("compare-normalized self-test passed");
  process.exit(0);
}

const expected = JSON.parse(fs.readFileSync(process.argv[4] ?? path.join(here, "normalized-expected.json"), "utf8"));
const appPath = process.argv[2];
if (!appPath) throw new Error("Usage: node compare-normalized.mjs APP_OUTPUT.json [OUTPUT.json] [EXPECTED.json]");
const app = JSON.parse(fs.readFileSync(appPath, "utf8"));
const result = compareRecords(expected, app);

const outputPath = process.argv[3] ?? path.join(here, "mismatches-current.json");
fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`);
const differing = result.filter((item) => item.mismatches.length);
console.log(`${result.length - differing.length}/${result.length} records match all asserted normalized fields; ${differing.length} differ.`);
for (const item of differing) console.log(`${item.rank}\t${item.id}\t${item.mismatches.map((mismatch) => mismatch.field).join(", ")}`);
