import fs from "node:fs";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
const expected = JSON.parse(fs.readFileSync(process.argv[4] ?? path.join(here, "normalized-expected.json"), "utf8"));
const appPath = process.argv[2];
if (!appPath) throw new Error("Usage: node compare-normalized.mjs APP_OUTPUT.json [OUTPUT.json]");
const app = JSON.parse(fs.readFileSync(appPath, "utf8"));
const appByID = new Map(app.map((item) => [item.id, item.bundle]));

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

const result = [];
for (const record of expected) {
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
  result.push({ id, rank: record.publicationRank, title: record.officialTitle, mismatches });
}

const outputPath = process.argv[3] ?? path.join(here, "mismatches-current.json");
fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`);
const differing = result.filter((item) => item.mismatches.length);
console.log(`${result.length - differing.length}/${result.length} records match all asserted normalized fields; ${differing.length} differ.`);
for (const item of differing) console.log(`${item.rank}\t${item.id}\t${item.mismatches.map((mismatch) => mismatch.field).join(", ")}`);
