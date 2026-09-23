import type {
  CandidateEntityRef,
  ParseContext,
  SourceAdapter,
  SourceSnapshot,
} from "../types.js";
import type { CheerioAPI } from "cheerio";
import type { AnyNode } from "domhandler";
import {
  absolute,
  baseResult,
  contextRef,
  fact,
  finish,
  load,
  media,
  parseJapaneseDateTime,
  parseJapaneseDateTimeWindow,
  parseJapaneseSchedules,
  PARSER_VERSION,
  selectedText,
  sourceKey,
  text,
  uniqueLinks,
  wholeEvent,
} from "./common.js";

const INDEX_ITEM_SELECTOR =
  ".livelist > li, #live-event-page .list li, #live-event-page .list a[href], section a[href*='live_detail']";

export const loveLiveBranchIndexAdapter: SourceAdapter = {
  id: "lovelive.branch-index",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const url = new URL(snapshot.finalUrl);
    const matched =
      url.hostname === "www.lovelive-anime.jp" &&
      ($(".livelist .live_title").length > 0 ||
        $("#live-event-page .live_title").length > 0 ||
        $("section a[href*='live_detail'] h2").length > 0);
    return {
      matched,
      reason: matched
        ? "verified branch-list template"
        : "no verified Love Live branch-list selector",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    const links = $(INDEX_ITEM_SELECTOR)
      .map((_i, item) => {
        const anchor = $(item).is("a")
          ? $(item)
          : $(item).find("a[href]").first();
        const title =
          text($(item).find(".live_title, h2").first().text()) ||
          text(anchor.find("img[alt]").first().attr("alt") ?? "");
        const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
        if (!url || !title) return undefined;
        return {
          url,
          title,
          role: "event" as const,
          sourceKey: sourceKey(url),
        };
      })
      .get()
      .filter(Boolean);
    return uniqueLinks(links);
  },
  extract(snapshot, _context) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    result.links.push(...this.discover(snapshot));
    for (const link of result.links) {
      const anchor = $(
        `a[href='${cssEscape(new URL(link.url).pathname + new URL(link.url).search)}'], a[href='${cssEscape(link.url)}']`,
      ).first();
      const container = anchor.closest("li").length
        ? anchor.closest("li")
        : anchor;
      const raw = text(container.text());
      const ref = { sourceKey: link.sourceKey };
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.officialTitle",
          link.title,
          "event-list item",
          raw || link.title || "",
          ["live-event list"],
        ),
      );
      const schedule = text(container.find(".live_date").first().text());
      const venue = text(container.find(".live_place").first().text());
      if (schedule)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "performance.scheduleRaw",
            schedule,
            ".live_date",
            schedule,
            ["live-event list"],
          ),
        );
      if (venue)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "performance.venueRaw",
            venue,
            ".live_place",
            venue,
            ["live-event list"],
          ),
        );
    }
    result.sections.push({
      name: "live-event list",
      locator: INDEX_ITEM_SELECTOR,
      status: "parsed",
    });
    return finish(result);
  },
};

export const loveLiveNewsAdapter: SourceAdapter = {
  id: "lovelive.news-index",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const matched =
      new URL(snapshot.finalUrl).hostname === "www.lovelive-anime.jp" &&
      $("li.c-card.p-articlelist__item .c-card__title").length > 0;
    return {
      matched,
      reason: matched
        ? "verified news card selector"
        : "missing Love Live news cards",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $("li.c-card.p-articlelist__item")
        .map((_i, node) => {
          const anchor = $(node).find("a.detailwrap").first();
          const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
          if (!url) return undefined;
          return {
            url,
            title: selectedText($, node, ".c-card__title"),
            role: "news" as const,
            sourceKey: sourceKey(url),
          };
        })
        .get()
        .filter(Boolean),
    );
  },
  extract(snapshot) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    result.links.push(...this.discover(snapshot));
    $("li.c-card.p-articlelist__item").each((index, node) => {
      const anchor = $(node).find("a.detailwrap").first();
      const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
      if (!url) return;
      const raw = text($(node).text());
      const ref = { sourceKey: sourceKey(url) };
      const title = selectedText($, node, ".c-card__title");
      if (title)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "notice.title",
            title,
            `li.c-card:nth-of-type(${index + 1})`,
            raw,
            ["news"],
          ),
        );
      const date = $(node).find("time").attr("datetime");
      if (date)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "notice.sourcePublishedDate",
            date,
            `li.c-card:nth-of-type(${index + 1}) time`,
            raw,
            ["news"],
          ),
        );
    });
    result.sections.push({
      name: "news",
      locator: "li.c-card.p-articlelist__item",
      status: "parsed",
    });
    return finish(result);
  },
};

export const loveLiveDetailAdapter: SourceAdapter = {
  id: "lovelive.live-detail",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const url = new URL(snapshot.finalUrl);
    const matched =
      url.hostname === "www.lovelive-anime.jp" &&
      /live_detail\.php$/.test(url.pathname) &&
      $("main article [data-target]").length > 0;
    return {
      matched,
      reason: matched
        ? "verified data-target detail template"
        : "missing Love Live detail data-target sections",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $("main article a[href]")
        .map((_i, node) => {
          const url = absolute($(node).attr("href") ?? "", snapshot.finalUrl);
          if (!url) return undefined;
          const title = text($(node).text());
          const role = /eplus|ticket|チケット/i.test(`${url} ${title}`)
            ? ("ticket" as const)
            : /goods|store|通販|グッズ/i.test(`${url} ${title}`)
              ? ("goods" as const)
              : ("unknown" as const);
          return { url, title: title || undefined, role };
        })
        .get()
        .filter(Boolean),
    );
  },
  extract(snapshot, context) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    const ref = contextRef(context, snapshot.finalUrl);
    const title = text(
      $("meta[property='og:description']").attr("content") ??
        $("meta[property='og:title']").attr("content") ??
        "",
    ).replace(/｜.*$/, "");
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.officialTitle",
          title,
          "meta[property='og:description']",
          title,
          ["header"],
          wholeEvent,
        ),
      );
    const seenTargets = new Set<string>();
    $("main article [data-target]").each((index, node) => {
      const target = $(node).attr("data-target") ?? "unknown";
      const raw = text($(node).text());
      if (!raw || seenTargets.has(`${target}:${raw}`)) return;
      seenTargets.add(`${target}:${raw}`);
      const locator = `[data-target='${target}']:nth-of-type(${index + 1})`;
      if (!result.sections.some((section) => section.name === target))
        result.sections.push({
          name: target,
          locator: `[data-target='${target}']`,
          status: "parsed",
        });
      if (target === "top")
        extractOverview(result, snapshot, context, ref, raw, locator);
      else if (target === "ticket2" || target === "ticket")
        extractTickets(result, snapshot, ref, raw, locator);
      else if (target === "goods")
        result.candidates.push(
          fact(snapshot, ref, "goods.campaignRaw", raw, locator, raw, [
            "goods",
          ]),
        );
    });
    $("main article [data-target] img[src]").each((index, image) => {
      const url = absolute($(image).attr("src") ?? "", snapshot.finalUrl);
      if (!url) return;
      const targetContainer = $(image).closest("[data-target]");
      const target = targetContainer.attr("data-target") ?? "unknown";
      const photo = $(image).closest("[data-type='component-photo']");
      const nearbyHeading =
        text(
          photo
            .prevAll("[data-type='component-midashi']")
            .first()
            .find("h3")
            .text(),
        ) || text(targetContainer.find("h3").first().text());
      const nearbyText = text(
        photo.prevAll("[data-type='component-text']").first().text(),
      );
      const sectionLabel = text(
        $(`.ke-ac_title[data-target='${cssEscape(target)}']`)
          .first()
          .text(),
      );
      const evidenceText = nearbyHeading || nearbyText || sectionLabel;
      if (!evidenceText) return;
      const goodsEvidence = `${sectionLabel} ${nearbyText}`;
      const purpose = /座席/.test(`${nearbyHeading} ${nearbyText}`)
        ? ("event_seating_map" as const)
        : target === "goods" &&
            /グッズ|事前通販|商品/.test(goodsEvidence) &&
            targetContainer.find("img[src]").length > 1
          ? ("goods_list" as const)
          : ("unknown" as const);
      result.media.push(
        media(
          ref,
          url,
          purpose,
          `[data-target='${target}'] img:nth-of-type(${index + 1})`,
          evidenceText,
          [sectionLabel || target, nearbyHeading].filter(Boolean),
        ),
      );
    });
    extractLoveLiveTypedSections($, snapshot, ref, result);
    result.links.push(...this.discover(snapshot));
    return finish(result);
  },
};

function extractLoveLiveTypedSections(
  $: CheerioAPI,
  snapshot: SourceSnapshot,
  ref: CandidateEntityRef,
  result: ReturnType<typeof baseResult>,
): void {
  const top = $("[data-target='top'].ke-accordion").first();
  const topChildren = top.children().toArray();
  let inCast = false;
  for (const [index, node] of topChildren.entries()) {
    const heading = text($(node).find("h3").first().text());
    if (heading) {
      inCast = /出演者/.test(heading);
      continue;
    }
    if (!inCast || !$(node).is("[data-textblock]")) continue;
    const raw = text($(node).text());
    const group = text($(node).find("strong").first().text());
    if (!raw || !group) continue;
    const groupStart = raw.indexOf(group);
    let body = groupStart >= 0 ? raw.slice(groupStart + group.length) : raw;
    body = body.replace(/作品サイト.*$/, "");
    const [mainBody, supportBody] = body.split(/応援出演[：:]/, 2);
    const role = /^ゲスト出演/.test(raw) ? "guest" : "on_stage";
    const performers = (mainBody ?? "")
      .split(/[、，]/)
      .map(text)
      .filter(Boolean);
    if (performers.length)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "performance.cast",
          { group, role, performers },
          `[data-target='top'].ke-accordion > :nth-child(${index + 1})`,
          raw,
          ["top", "出演者", group],
          {
            kind: "unresolved",
            rawText: "出演者 section does not label individual days",
          },
        ),
      );
    const supportPerformers = (supportBody ?? "")
      .split(/[、，]/)
      .map(text)
      .filter(Boolean);
    if (supportPerformers.length)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "performance.cast",
          { group, role: "support", performers: supportPerformers },
          `[data-target='top'].ke-accordion > :nth-child(${index + 1})`,
          raw,
          ["top", "出演者", group, "応援出演"],
          {
            kind: "unresolved",
            rawText: "出演者 section does not label individual days",
          },
        ),
      );
  }
  if (
    result.candidates.some(
      (candidate) => candidate.field === "performance.cast",
    )
  )
    result.issues.push({
      code: "unresolved_scope",
      message:
        "LL01 performer section does not explicitly divide cast by Day.1/Day.2; cast candidates require applicability review",
      locator: "[data-target='top'] h3",
      severity: "warning",
    });

  const ticket = $("[data-target='ticket'].ke-accordion").first();
  const children = ticket.children().toArray();
  for (let index = 0; index < children.length; index += 1) {
    const node = children[index]!;
    const heading = text($(node).find("h3").first().text());
    if (!heading) continue;
    const block: AnyNode[] = [];
    let cursor = index + 1;
    while (
      cursor < children.length &&
      !text($(children[cursor]!).find("h3").first().text())
    ) {
      block.push(children[cursor]!);
      cursor += 1;
    }
    const raw = text(block.map((item) => $(item).text()).join(" "));
    if (
      !/受付期間/.test(raw) ||
      block.some(
        (item) =>
          $(item).is(".ke-atension") || $(item).find(".ke-atension").length > 0,
      )
    )
      continue;
    emitLoveLiveRound(
      $,
      snapshot,
      ref,
      result,
      heading,
      raw,
      block,
      `[data-target='ticket'] h3:nth-of-type(${index + 1})`,
    );
  }
  ticket.find(".ke-atension").each((index, node) => {
    const heading = text($(node).find(".atension_header").first().text());
    const raw = text($(node).text());
    if (heading && /受付期間/.test(raw))
      emitLoveLiveRound(
        $,
        snapshot,
        ref,
        result,
        heading,
        raw,
        [node],
        `[data-target='ticket'] .ke-atension:nth-of-type(${index + 1})`,
      );
  });

  const upgradeRaw = text(
    $("[data-target='ticket2'].ke-accordion [data-textbody]")
      .filter((_i, node) => /アップグレード受付/.test($(node).text()))
      .first()
      .text(),
  );
  for (const match of upgradeRaw.matchAll(
    /【([12]次抽選)】(.+?)(?=【[12]次抽選】|【お申込み条件|$)/g,
  )) {
    const roundLabel = match[1]!;
    const roundRef = {
      ...ref,
      sourceKey: `${sourceKey(snapshot.finalUrl)}#ticket:upgrade-${roundLabel}`,
    };
    emitLoveLiveRound(
      $,
      snapshot,
      roundRef,
      result,
      `アップグレード受付 ${roundLabel}`,
      match[2]!,
      [],
      `[data-target='ticket2'] [data-textbody]::upgrade-${roundLabel}`,
      "アップグレード対象の購入済みチケット保持者",
    );
  }

  const goods = $("[data-target='goods'].ke-accordion").first();
  const goodsText = goods
    .find("[data-textbody]")
    .filter((_i, node) => /事前通販受付/.test($(node).text()))
    .first();
  const goodsRaw = text(goodsText.text());
  const goodsWindow = parseJapaneseDateTimeWindow(goodsRaw);
  const goodsUrl = absolute(
    goods.find("a.photoLink[href]").first().attr("href") ?? "",
    snapshot.finalUrl,
  );
  if (goodsWindow.startAt)
    result.candidates.push(
      fact(
        snapshot,
        ref,
        "goods.campaign",
        {
          officialName: "事前通販受付",
          channel: "online",
          fulfillment: "shipping",
          phase: "pre_event",
          salesStartAt: goodsWindow.startAt,
          ...(goodsWindow.endAt ? { salesEndAt: goodsWindow.endAt } : {}),
          ...(goodsUrl ? { url: goodsUrl } : {}),
          shippingNote: goodsRaw.match(/10月下旬以降順次発送[^※]*/)?.[0],
          windowRaw: goodsWindow.raw,
        },
        "[data-target='goods'] [data-textbody]",
        goodsRaw,
        ["goods", "事前通販受付"],
        {
          kind: "unresolved",
          rawText: "goods section does not explicitly state per-day scope",
        },
      ),
    );
}

function emitLoveLiveRound(
  $: CheerioAPI,
  snapshot: SourceSnapshot,
  ref: CandidateEntityRef,
  result: ReturnType<typeof baseResult>,
  heading: string,
  raw: string,
  nodes: AnyNode[],
  locator: string,
  eligibilityOverride?: string,
): void {
  const window = parseJapaneseDateTimeWindow(raw, "受付期間");
  if (!window.startAt) return;
  const resultAt = parseJapaneseDateTime(raw, "当落発表");
  const payment = parseJapaneseDateTimeWindow(raw, "入金期間");
  const url = nodes
    .flatMap((node) =>
      $(node)
        .find("a[href]")
        .map((_i, link) =>
          absolute($(link).attr("href") ?? "", snapshot.finalUrl),
        )
        .get(),
    )
    .find((candidate) => candidate?.includes("eplus.jp"));
  const eligibility =
    eligibilityOverride ??
    (/封入|申込券|ムビチケ|ご当選・ご購入/.test(raw) ? raw : undefined);
  result.candidates.push(
    fact(
      snapshot,
      ref,
      "ticket.round",
      {
        officialName: heading,
        kind: "lottery",
        applyStartAt: window.startAt,
        ...(window.endAt ? { applyEndAt: window.endAt } : {}),
        ...(resultAt ? { resultAt } : {}),
        ...(payment.endAt ? { paymentDeadlineAt: payment.endAt } : {}),
        ...(eligibility ? { eligibility } : {}),
        ...(url ? { applyURL: url } : {}),
        windowRaw: window.raw,
      },
      locator,
      raw,
      ["ticket", heading],
      {
        kind: "unresolved",
        rawText: /複数公演申込可能/.test(raw)
          ? "multiple performances explicitly permitted; membership unresolved"
          : "ticket section scope unresolved",
      },
    ),
  );
}

function extractOverview(
  result: ReturnType<typeof baseResult>,
  snapshot: SourceSnapshot,
  context: ParseContext,
  ref: CandidateEntityRef,
  raw: string,
  locator: string,
): void {
  for (const schedule of parseJapaneseSchedules(raw)) {
    const label = schedule.dayLabel ?? "single";
    const value = schedule.dayLabel
      ? schedule
      : { ...schedule, dayLabel: "single" };
    const entityRef = context.performanceRefs?.[label]
      ? { ...ref, performanceId: context.performanceRefs[label] }
      : {
          ...ref,
          sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${label}`,
        };
    result.candidates.push(
      fact(
        snapshot,
        entityRef,
        "performance.schedule",
        value,
        locator,
        schedule.raw,
        ["top", "日程・会場"],
      ),
    );
  }
  const venue = raw.match(/(?:■会場|会場)[：:]?\s*([^■]+?)(?=出演|■|$)/)?.[1];
  if (venue)
    result.candidates.push(
      fact(snapshot, ref, "performance.venueRaw", text(venue), locator, venue, [
        "top",
        "日程・会場",
      ]),
    );
}

function extractTickets(
  result: ReturnType<typeof baseResult>,
  snapshot: SourceSnapshot,
  ref: CandidateEntityRef,
  raw: string,
  locator: string,
): void {
  const prices = [
    ...raw.matchAll(/([^\n■]{1,50}?)[：:]\s*(＋|\+)?\s*([\d,]+)円/g),
  ].map((match) => ({
    name: text(match[1]!),
    amount: Number(match[3]!.replaceAll(",", "")),
    currency: "JPY",
    priceKind:
      match[2] || /アップグレード/.test(match[1]!)
        ? "upgrade_difference"
        : /U-?20/i.test(match[1]!)
          ? "under20"
          : "full",
    raw: match[0],
  }));
  if (prices.length)
    result.candidates.push(
      fact(snapshot, ref, "ticket.tiers", prices, locator, raw, [
        "ticket",
        "チケット料金",
      ]),
    );
  if (/受付期間|申込期間/.test(raw))
    result.candidates.push(
      fact(snapshot, ref, "ticket.roundsRaw", raw, locator, raw, [
        "ticket",
        "受付",
      ]),
    );
}

function cssEscape(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("'", "\\'");
}
