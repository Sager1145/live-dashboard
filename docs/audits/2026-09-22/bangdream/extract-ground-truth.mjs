import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { load } from "../../../../server/node_modules/cheerio/dist/esm/index.js";

const here = path.dirname(new URL(import.meta.url).pathname);
const publicationRecords = JSON.parse(
  fs.readFileSync(path.join(here, "events-publication-order.json"), "utf8"),
);

const clean = (value) =>
  String(value ?? "")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

function textWithBreaks($, node) {
  const clone = $(node).clone();
  clone.find("br").replaceWith("\n");
  return clean(clone.text());
}

function cssIndex($, node) {
  const element = $(node);
  const tag = String(node.tagName ?? node.name ?? "node").toLowerCase();
  const id = element.attr("id");
  if (id) return `${tag}#${id}`;
  const parent = element.parent();
  const siblings = parent.children(tag);
  return `${tag}:nth-of-type(${siblings.index(element) + 1})`;
}

function sectionAfter($, heading) {
  const level = Number(String(heading.tagName).slice(1));
  const nodes = [];
  let current = $(heading).next();
  while (current.length) {
    const tag = String(current[0].tagName ?? "").toLowerCase();
    if (/^h[1-6]$/.test(tag) && Number(tag.slice(1)) <= level) break;
    nodes.push(current[0]);
    current = current.next();
  }
  return nodes;
}

function firstSection($, matcher) {
  let result = null;
  $(".p-live-event-detail__content h2, .p-live-event-detail__content h3, .p-page-detail__content h2, .p-page-detail__content h3").each((_index, heading) => {
    if (result || !matcher.test(clean($(heading).text()))) return;
    const nodes = sectionAfter($, heading);
    result = {
      heading: clean($(heading).text()),
      locator: `.c-post-content > ${cssIndex($, heading)}`,
      text: clean(nodes.map((node) => textWithBreaks($, node)).join("\n")),
    };
  });
  return result;
}

function precedingTopHeading($, content, element, headingSelector = "h2") {
  let block = $(element);
  while (block.parent().length && block.parent()[0] !== content[0]) block = block.parent();
  return clean(block.prevAll(headingSelector).first().text());
}

const output = [];
const manifest = [];

for (const [index, record] of publicationRecords.entries()) {
  const htmlPath = path.join(here, "html", `${record.id}-${record.slug}.html`);
  const html = fs.readFileSync(htmlPath, "utf8");
  const $ = load(html);
  const content = $(".p-live-event-detail__content, .p-page-detail__content").first();
  const title = clean(
    $("h1.p-live-event-detail__header-title, h1.p-page-detail__header-title").first().text(),
  );
  const summary = {};
  $(".p-live-event-detail__table tr").each((rowIndex, row) => {
    const label = clean($(row).find("th").first().text());
    const value = textWithBreaks($, $(row).find("td").first());
    if (label) {
      summary[label] = {
        value,
        locator: `.p-live-event-detail__table tr:nth-child(${rowIndex + 1})`,
      };
    }
  });

  const schedule = firstSection($, /^(日程(?:・会場)?|日時|開催日時|開催概要)$/);
  const venue = firstSection($, /^(会場|場所|日程・会場|開催概要)$/);
  const performers = firstSection($, /^(出演|出演者|出演予定|出演（.*）|アーティスト)$/);
  const ticket = firstSection($, /^(?:会場)?チケット(?:情報)?$/);
  const prices = firstSection($, /^(料金|チケット料金)$/);

  const ticketRounds = [];
  content.find("h3,h4,h5,h6").each((_headingIndex, heading) => {
    const name = clean($(heading).text());
    const parentSection = clean($(heading).prevAll("h2").first().text());
    if (!/(チケット|お申し込み)/.test(parentSection)) return;
    if (!/(先行|一般発売|当日券|受付|販売|抽選|先着|リセール|申込期間)/.test(name)) return;
    if (/^(販売情報|チケット販売情報|販売スケジュール)$/.test(name)) return;
    const nodes = sectionAfter($, heading);
    const details = clean(nodes.map((node) => textWithBreaks($, node)).join("\n"));
    ticketRounds.push({
      name,
      details,
      locator: `.c-post-content > ${cssIndex($, heading)}`,
      links: nodes.flatMap((node) =>
        $(node)
          .find("a[href]")
          .toArray()
          .map((anchor) => ({
            label: clean($(anchor).text()),
            url: $(anchor).attr("href"),
          })),
      ),
    });
  });

  const eventGoodsLinks = [];
  content.find("a[href]").each((_linkIndex, anchor) => {
    const url = $(anchor).attr("href");
    const label = clean($(anchor).text());
    const section = precedingTopHeading($, content, anchor, "h2");
    if (/(goods|グッズ|物販|bushiroad-store|bushiroad-creative)/i.test(`${url} ${label} ${section}`)) {
      eventGoodsLinks.push({ label, url, locator: `.c-post-content a[href="${url}"]` });
    }
  });
  const globalGoodsBannerLinks = [];
  $(".p-live-event-detail__goods-banner a[href]").each((_linkIndex, anchor) => {
    globalGoodsBannerLinks.push({
      label: clean($(anchor).find("img").attr("alt")),
      url: $(anchor).attr("href"),
      locator: ".p-live-event-detail__goods-banner a",
    });
  });

  const images = [];
  const eventGoodsImages = [];
  $(".p-live-event-detail__eyecatch img[src], .p-live-event-detail__content img[src], .p-page-detail__content img[src]").each(
    (_imageIndex, image) => {
      const item = {
        url: $(image).attr("src"),
        alt: clean($(image).attr("alt")),
        locator: $(image).closest(".p-live-event-detail__eyecatch").length
          ? ".p-live-event-detail__eyecatch img"
          : `.c-post-content img:nth-of-type(${_imageIndex + 1})`,
      };
      images.push(item);
      if ($(image).closest(".c-post-content").length) {
        const section = precedingTopHeading($, content, image, "h2");
        if (/(グッズ|物販)/.test(section)) {
          const linkedURL = $(image).closest("a[href]").attr("href") || null;
          eventGoodsImages.push({
            ...item,
            linkedOriginalURL: linkedURL && /\.(?:png|jpe?g|webp)(?:\?.*)?$/i.test(linkedURL) ? linkedURL : null,
            section,
            caption: precedingTopHeading($, content, image, "h2,h3,h4,h5,h6"),
          });
        }
      }
    },
  );

  const relatedArtists = $(".p-live-event-detail__related-artist a")
    .toArray()
    .map((anchor) => clean($(anchor).text()))
    .filter(Boolean);

  manifest.push({
    id: `bangdream-${record.id}`,
    url: record.link,
    path: htmlPath,
    title,
    franchise: "bangdream",
    groups: [],
  });

  output.push({
    publicationRank: index + 1,
    wordpressID: record.id,
    publishedAtLocal: record.date,
    modifiedAtLocal: record.modified,
    url: record.link,
    cachedHTML: htmlPath,
    cachedHTMLBytes: Buffer.byteLength(html),
    cachedHTMLSHA256: crypto.createHash("sha256").update(html).digest("hex"),
    title: {
      value: title,
      locator: "h1.p-live-event-detail__header-title, h1.p-page-detail__header-title",
    },
    category: {
      value:
        clean($(".p-live-event-detail__header-category").first().text()) ||
        (record.tax_events?.includes(51) ? "ライブ" : ""),
      locator: ".p-live-event-detail__header-category",
    },
    summary,
    schedule,
    venue,
    performers,
    prices,
    ticketSection: ticket,
    ticketRounds,
    eventGoodsLinks,
    eventGoodsImages,
    globalGoodsBannerLinks,
    images,
    relatedArtists,
  });
}

fs.writeFileSync(path.join(here, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
fs.writeFileSync(path.join(here, "ground-truth.json"), `${JSON.stringify(output, null, 2)}\n`);

const archiveHTML = fs.readFileSync(path.join(here, "events-index.html"), "utf8");
const archive = load(archiveHTML);
const archiveOrder = archive(".p-live-event-list__item")
  .toArray()
  .map((item, index) => {
    const row = archive(item);
    return {
      archiveRank: index + 1,
      url: row.find("a.p-live-event-list__item-link").attr("href"),
      title: clean(row.find(".p-live-event-list__item-title").text()),
      category: clean(row.find(".p-live-event-list__item-category").text()),
      displayedEventDate: clean(row.find(".p-live-event-list__item-date + p").text()),
      displayedVenue: clean(row.find(".p-live-event-list__item-place + p").text()),
    };
  });
fs.writeFileSync(
  path.join(here, "archive-event-date-order.json"),
  `${JSON.stringify(archiveOrder, null, 2)}\n`,
);

console.log(
  `Wrote ${manifest.length} manifest entries, ${output.length} ground-truth records, and ${archiveOrder.length} archive-order records.`,
);
