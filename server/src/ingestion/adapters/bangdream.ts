import type {
  ParseContext,
  ParseResult,
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
  ticketLinksAndProducts,
  text,
  uniqueLinks,
  wholeEvent,
} from "./common.js";

export const bangDreamIndexAdapter: SourceAdapter = {
  id: "bangdream.event-index",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const matched =
      new URL(snapshot.finalUrl).hostname === "bang-dream.com" &&
      $(".p-live-event-list__item").length > 0;
    return {
      matched,
      reason: matched
        ? "verified event-list item selector"
        : "missing .p-live-event-list__item",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    const links = $(".p-live-event-list__item")
      .map((_i, node) => {
        const anchor = $(node).find("a.p-live-event-list__item-link").first();
        const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
        if (!url) return undefined;
        return {
          url,
          title: selectedText($, node, ".p-live-event-list__item-title"),
          role: "event" as const,
          sourceKey: sourceKey(url),
        };
      })
      .get()
      .filter(Boolean);
    return uniqueLinks(links);
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
    result.links.push(...this.discover(snapshot));
    $(".p-live-event-list__item").each((index, node) => {
      const anchor = $(node).find("a.p-live-event-list__item-link").first();
      const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
      if (!url) return;
      const ref = { sourceKey: sourceKey(url) };
      const title = selectedText($, node, ".p-live-event-list__item-title");
      const category = selectedText(
        $,
        node,
        ".p-live-event-list__item-category",
      );
      const itemText = text($(node).text());
      const locator = `.p-live-event-list__item:nth-of-type(${index + 1})`;
      if (title)
        result.candidates.push(
          fact(snapshot, ref, "event.officialTitle", title, locator, itemText, [
            "events",
          ]),
        );
      if (category)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "event.categoryRaw",
            category,
            locator,
            itemText,
            ["events"],
          ),
        );
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.discoverySummary",
          itemText,
          locator,
          itemText,
          ["events"],
        ),
      );
    });
    result.sections.push({
      name: "events",
      locator: ".p-live-event-list__item",
      status: "parsed",
    });
    return finish(result);
  },
};

export const bangDreamDetailAdapter: SourceAdapter = {
  id: "bangdream.event-detail",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const matched =
      new URL(snapshot.finalUrl).hostname === "bang-dream.com" &&
      $(
        "article.p-live-event-detail .p-live-event-detail__content, article.p-page-detail .p-page-detail__content",
      ).length === 1;
    return {
      matched,
      reason: matched
        ? "verified detail/article selector"
        : "missing BanG Dream detail content",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $("article.p-live-event-detail a[href], article.p-page-detail a[href]")
        .map((_i, node) => {
          const url = absolute($(node).attr("href") ?? "", snapshot.finalUrl);
          if (!url) return undefined;
          const label = text($(node).text());
          const role = /チケット|eplus|ticket/i.test(`${label} ${url}`)
            ? ("ticket" as const)
            : /グッズ|通販|goods|store/i.test(`${label} ${url}`)
              ? ("goods" as const)
              : /\/events\//.test(new URL(url).pathname)
                ? ("event" as const)
                : ("unknown" as const);
          return {
            url,
            title: label || undefined,
            role,
            ...(/\/events\//.test(new URL(url).pathname)
              ? { sourceKey: sourceKey(url) }
              : {}),
          };
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
    const titleSelector =
      ".p-live-event-detail__header-title, .p-page-detail__header-title";
    const title = text($(titleSelector).first().text());
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.officialTitle",
          title,
          titleSelector,
          title,
          ["header"],
          wholeEvent,
        ),
      );
    $(".p-live-event-detail__table tr").each((index, row) => {
      const label = selectedText($, row, "th");
      const value = selectedText($, row, "td");
      if (label && value)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            `event.summary.${label}`,
            value,
            `.p-live-event-detail__table tr:nth-child(${index + 1})`,
            `${label} ${value}`,
            ["summary"],
            wholeEvent,
          ),
        );
    });
    const content = $(
      ".p-live-event-detail__content, .p-page-detail__content",
    ).first();
    let heading = "content";
    content.children().each((index, node) => {
      const name = (node as { name?: string }).name?.toLowerCase();
      if (/^h[1-6]$/.test(name ?? "")) {
        heading = text($(node).text());
        result.sections.push({
          name: heading,
          locator: `.p-live-event-detail__content > :nth-child(${index + 1})`,
          status: "parsed",
        });
        return;
      }
      const raw = text($(node).text());
      if (!raw || raw === " ") return;
      const locator = `.p-live-event-detail__content > :nth-child(${index + 1})`;
      if (heading === "日程") {
        result.candidates.push(
          fact(snapshot, ref, "performance.scheduleRaw", raw, locator, raw, [
            heading,
          ]),
        );
        for (const schedule of parseJapaneseSchedules(raw)) {
          const inferred =
            schedule.dayLabel ??
            raw
              .match(/DAY\s*\d+/i)?.[0]
              ?.replace(/\s+/g, "")
              .toUpperCase() ??
            title
              .match(/DAY\s*\d+/i)?.[0]
              ?.replace(/\s+/g, "")
              .toUpperCase() ??
            "single";
          const label = inferred.replace(/^DAY(\d+)$/, "DAY$1");
          const value = { ...schedule, dayLabel: label };
          const performanceId = context.performanceRefs?.[label];
          const performanceRef = performanceId
            ? { ...ref, performanceId }
            : {
                ...ref,
                sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${label}`,
              };
          result.candidates.push(
            fact(
              snapshot,
              performanceRef,
              "performance.schedule",
              value,
              locator,
              schedule.raw,
              [heading],
              performanceId
                ? { kind: "performances", performanceIds: [performanceId] }
                : { kind: "unresolved", rawText: label },
            ),
          );
        }
      } else if (/^(?:会場|場所)$/.test(heading))
        result.candidates.push(
          fact(snapshot, ref, "performance.venueRaw", raw, locator, raw, [
            heading,
          ]),
        );
      else if (/出演/.test(heading)) {
        const perDay = [
          ...raw.matchAll(
            /DAY\s*(\d+)\s*[：:]\s*(.+?)(?=DAY\s*\d+\s*[：:]|$)/gi,
          ),
        ];
        if (perDay.length)
          for (const match of perDay) {
            const label = `DAY${match[1]}`;
            const performanceId = context.performanceRefs?.[label];
            const performanceRef = performanceId
              ? { ...ref, performanceId }
              : {
                  ...ref,
                  sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${label}`,
                };
            result.candidates.push(
              fact(
                snapshot,
                performanceRef,
                "performance.performers",
                [text(match[2]!)],
                locator,
                match[0],
                [heading],
                performanceId
                  ? { kind: "performances", performanceIds: [performanceId] }
                  : { kind: "unresolved", rawText: label },
              ),
            );
          }
        else {
          const performers = raw
            .split(/[、,，／/]/)
            .map(text)
            .filter(Boolean);
          result.candidates.push(
            fact(
              snapshot,
              ref,
              "performance.performers",
              performers,
              locator,
              raw,
              [heading],
            ),
          );
        }
      } else if (/オープニングアクト/.test(heading))
        result.candidates.push(
          fact(snapshot, ref, "performance.openingActRaw", raw, locator, raw, [
            heading,
          ]),
        );
      else if (/料金/.test(heading)) {
        const tiers = [
          ...raw
            .normalize("NFKC")
            .matchAll(/([^:：]{1,60})[：:]\s*([\d,]+)円/g),
        ].map((match) => ({
          name: text(match[1]!),
          amount: Number(match[2]!.replaceAll(",", "")),
          currency: "JPY",
          priceKind: "full",
          raw: match[0],
        }));
        if (tiers.length)
          result.candidates.push(
            fact(snapshot, ref, "ticket.tiers", tiers, locator, raw, [
              "チケット",
              heading,
            ]),
          );
        else
          result.candidates.push(
            fact(snapshot, ref, "ticket.sectionRaw", raw, locator, raw, [
              heading,
            ]),
          );
      } else if (/発売|先行|抽選|受付/.test(heading) && /受付期間/.test(raw))
        result.candidates.push(
          fact(snapshot, ref, "ticket.roundRaw", raw, locator, raw, [
            "チケット",
            heading,
          ]),
        );
      else if (/チケット/.test(heading))
        result.candidates.push(
          fact(snapshot, ref, "ticket.sectionRaw", raw, locator, raw, [
            heading,
          ]),
        );
      else if (/グッズ|物販|goods/i.test(heading))
        result.candidates.push(
          fact(snapshot, ref, "goods.campaignRaw", raw, locator, raw, [
            heading,
          ]),
        );
      else if (/配信/.test(heading))
        result.candidates.push(
          fact(snapshot, ref, "stream.sectionRaw", raw, locator, raw, [
            heading,
          ]),
        );
    });
    extractCombinedScheduleVenue(
      $,
      content.toArray()[0]!,
      snapshot,
      context,
      ref,
      result,
    );
    extractBangDreamCommerce(
      $,
      content.toArray()[0]!,
      snapshot,
      context,
      ref,
      title,
      result,
    );
    extractBangDreamAncillary(
      $,
      content.toArray()[0]!,
      snapshot,
      context,
      ref,
      result,
    );
    $(".p-live-event-detail__eyecatch img").each((_i, image) => {
      const url = absolute($(image).attr("src") ?? "", snapshot.finalUrl);
      if (url)
        result.media.push(
          media(
            ref,
            url,
            "key_visual",
            ".p-live-event-detail__eyecatch img",
            title,
            ["header"],
          ),
        );
    });
    result.links.push(...this.discover(snapshot));
    return finish(result);
  },
};

function extractCombinedScheduleVenue(
  $: CheerioAPI,
  contentNode: AnyNode,
  snapshot: SourceSnapshot,
  context: ParseContext,
  ref: ReturnType<typeof contextRef>,
  result: ReturnType<typeof baseResult>,
): void {
  const children = $(contentNode).children().toArray();
  const start = children.findIndex(
    (node) =>
      (node as { name?: string }).name?.toLowerCase() === "h2" &&
      text($(node).text()) === "日程・会場",
  );
  if (start < 0) return;
  let end = start + 1;
  while (
    end < children.length &&
    (children[end] as { name?: string }).name?.toLowerCase() !== "h2"
  )
    end += 1;
  let subheading = "";
  for (let index = start + 1; index < end; index += 1) {
    const node = children[index]!;
    const tag = (node as { name?: string }).name?.toLowerCase() ?? "";
    if (/^h[3-6]$/.test(tag)) {
      subheading = text($(node).text());
      continue;
    }
    const raw = text($(node).text());
    if (!raw) continue;
    for (const schedule of parseJapaneseSchedules(raw)) {
      const explicitDay =
        schedule.dayLabel ??
        raw
          .match(/DAY\s*\d+/i)?.[0]
          ?.replace(/\s+/g, "")
          .toUpperCase();
      const dayLabel =
        explicitDay ?? (/公演$/.test(subheading) ? subheading : "single");
      const performanceId = context.performanceRefs?.[dayLabel];
      const performanceRef = performanceId
        ? { ...ref, performanceId }
        : {
            ...ref,
            sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${dayLabel}`,
          };
      const applicability = performanceId
        ? { kind: "performances" as const, performanceIds: [performanceId] }
        : { kind: "unresolved" as const, rawText: dayLabel };
      result.candidates.push(
        fact(
          snapshot,
          performanceRef,
          "performance.schedule",
          { ...schedule, dayLabel },
          `.p-live-event-detail__content > :nth-child(${index + 1})`,
          schedule.raw,
          ["日程・会場", ...(subheading ? [subheading] : [])],
          applicability,
        ),
      );
      const venue = raw.match(/会場\s*[：:]\s*(.+)$/)?.[1];
      if (venue)
        result.candidates.push(
          fact(
            snapshot,
            performanceRef,
            "performance.venueRaw",
            text(venue),
            `.p-live-event-detail__content > :nth-child(${index + 1})`,
            raw,
            ["日程・会場", ...(subheading ? [subheading] : [])],
            applicability,
          ),
        );
    }
    if (!/\d{4}年/.test(raw)) {
      const venue = raw.match(/会場\s*[：:]\s*(.+)$/)?.[1];
      if (venue)
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "performance.venueRaw",
            text(venue),
            `.p-live-event-detail__content > :nth-child(${index + 1})`,
            raw,
            ["日程・会場", ...(subheading ? [subheading] : [])],
          ),
        );
    }
  }
}

function extractBangDreamCommerce(
  $: CheerioAPI,
  contentNode: AnyNode,
  snapshot: SourceSnapshot,
  context: ParseContext,
  ref: ReturnType<typeof contextRef>,
  title: string,
  result: ReturnType<typeof baseResult>,
): void {
  const children = $(contentNode).children().toArray();
  let section = "";
  const pageLabel = title
    .match(/DAY\s*\d+/i)?.[0]
    ?.replace(/\s+/g, "")
    .toUpperCase();
  for (let index = 0; index < children.length; index += 1) {
    const node = children[index]!;
    const tag = (node as { name?: string }).name?.toLowerCase() ?? "";
    if (tag === "h2") {
      section = text($(node).text());
      continue;
    }
    if (!/^h[3-6]$/.test(tag)) continue;
    const heading = text($(node).text());
    const block: AnyNode[] = [];
    let cursor = index + 1;
    while (
      cursor < children.length &&
      !/^h[2-6]$/.test(
        (children[cursor] as { name?: string }).name?.toLowerCase() ?? "",
      )
    ) {
      block.push(children[cursor]!);
      cursor += 1;
    }
    const blockRaw = text(block.map((item) => $(item).text()).join(" "));
    const blockUrls = uniqueLinks(
      block.flatMap((item) =>
        $(item)
          .find("a[href]")
          .map((_i, link) => {
            const url = absolute($(link).attr("href") ?? "", snapshot.finalUrl);
            return url ? [{ url, role: "ticket" as const }] : [];
          })
          .get(),
      ),
    ).map((link) => link.url);
    if (section === "チケット" && /発売|先行|抽選|チケット/.test(heading)) {
      const groups = ticketRoundGroups($, block);
      let emittedRound = false;
      for (const { nodes, offset } of groups) {
        const raw = text(nodes.map((item) => $(item).text()).join(" "));
        const window = parseJapaneseDateTimeWindow(raw, "受付期間");
        if (!window.startAt) continue;
        const namedDay = raw
          .match(/DAY\s*\d+/i)?.[0]
          ?.replace(/\s+/g, "")
          .toUpperCase();
        const dayLabel =
          namedDay ??
          (!/3DAYS|通し/.test(`${heading} ${raw}`) ? pageLabel : undefined);
        const performanceId = dayLabel
          ? context.performanceRefs?.[dayLabel]
          : undefined;
        const performanceRef = performanceId
          ? { ...ref, performanceId }
          : dayLabel
            ? {
                ...ref,
                sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${dayLabel}`,
              }
            : ref;
        const ticketDetails = ticketLinksAndProducts(
          $,
          nodes,
          snapshot.finalUrl,
        );
        const applicationLinks = ticketDetails.links.filter(
          (link) => link.role === "application",
        );
        const overseasLinks = ticketDetails.links.filter(
          (link) => link.role === "overseasApplication",
        );
        const eligibility = /封入|申込券|シリアル/.test(raw)
          ? raw
          : /封入|申込券|シリアル/.test(blockRaw)
            ? blockRaw
            : undefined;
        const value = {
          officialName: `${heading}${namedDay ? ` ${namedDay}` : ""}`,
          kind:
            /先着順/.test(blockRaw) || /一般発売/.test(heading)
              ? "first_come"
              : "lottery",
          ...(dayLabel ? { dayLabel } : {}),
          applyStartAt: window.startAt,
          ...(window.endAt ? { applyEndAt: window.endAt } : {}),
          ...(parseJapaneseDateTime(raw, "当落発表")
            ? { resultAt: parseJapaneseDateTime(raw, "当落発表") }
            : {}),
          ...(parseJapaneseDateTimeWindow(raw, "入金期間").endAt
            ? {
                paymentDeadlineAt: parseJapaneseDateTimeWindow(raw, "入金期間")
                  .endAt,
              }
            : {}),
          ...(eligibility ? { eligibility } : {}),
          ...(applicationLinks[0] ? { applyURL: applicationLinks[0].url } : {}),
          ...(overseasLinks[0] ? { overseasURL: overseasLinks[0].url } : {}),
          ...(ticketDetails.links.length ? { links: ticketDetails.links } : {}),
          ...(ticketDetails.lotteryProducts.length
            ? { lotteryProducts: ticketDetails.lotteryProducts }
            : {}),
          ...(namedDay ? { applicationTarget: namedDay } : {}),
          applyWindowText: window.raw,
          windowRaw: window.raw,
        };
        result.candidates.push(
          fact(
            snapshot,
            performanceRef,
            "ticket.round",
            value,
            `.p-live-event-detail__content > :nth-child(${index + offset + 2})`,
            raw,
            ["チケット", heading],
            performanceId
              ? { kind: "performances", performanceIds: [performanceId] }
              : dayLabel
                ? { kind: "unresolved", rawText: dayLabel }
                : { kind: "unresolved", rawText: "3DAYS or unspecified" },
          ),
        );
        emittedRound = true;
      }
      if (
        !emittedRound &&
        /封入|申込券|シリアル/.test(blockRaw) &&
        /後日公開|後日発表|追って|未定/.test(blockRaw)
      ) {
        const ticketDetails = ticketLinksAndProducts(
          $,
          block,
          snapshot.finalUrl,
        );
        const officialStatus =
          blockRaw.match(
            /[^。]*(?:後日公開|後日発表|追って|未定)[^。]*。?/,
          )?.[0] ?? "後日公開";
        result.candidates.push(
          fact(
            snapshot,
            ref,
            "ticket.round",
            {
              officialName: heading,
              kind: "lottery",
              eligibility: blockRaw,
              officialStatus,
              status: "officiallyTBA",
              ...(ticketDetails.links.length
                ? { links: ticketDetails.links }
                : {}),
              ...(ticketDetails.lotteryProducts.length
                ? { lotteryProducts: ticketDetails.lotteryProducts }
                : {}),
            },
            `.p-live-event-detail__content > :nth-child(${index + 1})`,
            blockRaw,
            ["チケット", heading],
          ),
        );
      }
    }
    if (
      /グッズ|物販/.test(section) &&
      /通販|オンライン/.test(`${heading} ${blockRaw}`)
    ) {
      const timing = block
        .map((item) => ({ item, raw: text($(item).text()) }))
        .find(({ raw }) => /\d{4}年\d{1,2}月\d{1,2}日/.test(raw));
      if (!timing) continue;
      const window = parseJapaneseDateTimeWindow(timing.raw);
      if (!window.startAt) continue;
      const url = blockUrls.find(
        (candidate) => new URL(candidate).hostname === "bushiroad-store.com",
      );
      const dayLabel = pageLabel;
      const performanceId = dayLabel
        ? context.performanceRefs?.[dayLabel]
        : undefined;
      const performanceRef = performanceId ? { ...ref, performanceId } : ref;
      result.candidates.push(
        fact(
          snapshot,
          performanceRef,
          "goods.campaign",
          {
            officialName: heading,
            channel: "online",
            fulfillment: "shipping",
            phase: "pre_event",
            ...(dayLabel ? { dayLabel } : {}),
            salesStartAt: window.startAt,
            ...(window.endAt ? { salesEndAt: window.endAt } : {}),
            ...(url ? { url } : {}),
            windowRaw: window.raw,
          },
          `.p-live-event-detail__content > :nth-child(${index + 2})`,
          timing.raw,
          [section, heading],
          performanceId
            ? { kind: "performances", performanceIds: [performanceId] }
            : dayLabel
              ? { kind: "unresolved", rawText: dayLabel }
              : { kind: "unresolved" },
        ),
      );
    }
  }
}

function ticketRoundGroups(
  $: CheerioAPI,
  block: readonly AnyNode[],
): { nodes: AnyNode[]; offset: number }[] {
  const starts = block
    .map((node, index) => (/受付期間/.test(text($(node).text())) ? index : -1))
    .filter((index) => index >= 0);
  return starts.map((start, index) => ({
    nodes: block.slice(
      index === 0 ? 0 : start,
      starts[index + 1] ?? block.length,
    ),
    offset: index === 0 ? 0 : start,
  }));
}

function extractBangDreamAncillary(
  $: CheerioAPI,
  contentNode: AnyNode,
  snapshot: SourceSnapshot,
  context: ParseContext,
  ref: ReturnType<typeof contextRef>,
  result: ReturnType<typeof baseResult>,
): void {
  const children = $(contentNode).children().toArray();
  const h2Sections = children
    .map((node, index) => ({
      node,
      index,
      tag: (node as { name?: string }).name?.toLowerCase(),
      heading: text($(node).text()),
    }))
    .filter((entry) => entry.tag === "h2");
  const sectionNodes = (entry: (typeof h2Sections)[number]) =>
    children.slice(
      entry.index,
      h2Sections.find((next) => next.index > entry.index)?.index ??
        children.length,
    );
  const scoped = (label = "single") => {
    const performanceId = context.performanceRefs?.[label];
    return {
      entityRef: performanceId
        ? { ...ref, performanceId }
        : {
            ...ref,
            sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:${label}`,
          },
      applicability: performanceId
        ? { kind: "performances" as const, performanceIds: [performanceId] }
        : { kind: "unresolved" as const, rawText: label },
    };
  };

  const streamSection = h2Sections.find((entry) =>
    /配信チケット/.test(entry.heading),
  );
  if (streamSection) {
    const nodes = sectionNodes(streamSection);
    const sectionRaw = text(nodes.map((node) => $(node).text()).join(" "));
    const salesHeading = nodes.findIndex(
      (node) =>
        /^h[3-6]$/.test(
          (node as { name?: string }).name?.toLowerCase() ?? "",
        ) && /販売情報/.test(text($(node).text())),
    );
    const salesNodes =
      salesHeading >= 0
        ? nodes.slice(salesHeading + 1, nextHeadingIndex(nodes, salesHeading))
        : [];
    const salesRaw = text(salesNodes.map((node) => $(node).text()).join(" "));
    const saleWindow = parseJapaneseDateTimeWindow(salesRaw, "販売期間");
    const archiveAvailableUntil = parseJapaneseDateTime(salesRaw, "配信期間");
    const urls = nodes
      .flatMap((node) =>
        $(node)
          .find("a[href]")
          .map((_i, link) =>
            absolute($(link).attr("href") ?? "", snapshot.finalUrl),
          )
          .get(),
      )
      .filter(Boolean);
    const purchaseURL = urls.find(
      (url) => new URL(url!).hostname === "eplus.jp",
    );
    const overseasURL = urls.find(
      (url) => new URL(url!).hostname === "ib.eplus.jp",
    );
    const price = sectionRaw.match(/料金\s*([\d,]+)円/)?.[1];
    if (saleWindow.endAt && purchaseURL) {
      const scope = scoped();
      result.candidates.push(
        fact(
          snapshot,
          scope.entityRef,
          "stream.offer",
          {
            officialName: streamSection.heading,
            platform: "eplus",
            ...(price
              ? {
                  amount: {
                    minorUnits: Number(price.replaceAll(",", "")),
                    currency: "JPY",
                  },
                }
              : {}),
            salesStartAt: saleWindow.startAt,
            salesEndAt: saleWindow.endAt,
            ...(archiveAvailableUntil ? { archiveAvailableUntil } : {}),
            url: purchaseURL,
            ...(overseasURL ? { overseasURL } : {}),
          },
          `.p-live-event-detail__content > :nth-child(${streamSection.index + 1})::section`,
          sectionRaw,
          [streamSection.heading],
          scope.applicability,
        ),
      );
    }
  }

  const resaleSection = h2Sections.find((entry) =>
    /チケットトレード/.test(entry.heading),
  );
  if (resaleSection) {
    const nodes = sectionNodes(resaleSection);
    const sectionRaw = text(nodes.map((node) => $(node).text()).join(" "));
    const periodHeading = nodes.findIndex((node) =>
      /トレード受付期間/.test(text($(node).text())),
    );
    const periodRaw =
      periodHeading >= 0
        ? text(
            nodes
              .slice(periodHeading + 1, nextHeadingIndex(nodes, periodHeading))
              .map((node) => $(node).text())
              .join(" "),
          )
        : "";
    const window = parseJapaneseDateTimeWindow(periodRaw);
    const applyURL = nodes
      .flatMap((node) =>
        $(node)
          .find("a[href]")
          .map((_i, link) =>
            absolute($(link).attr("href") ?? "", snapshot.finalUrl),
          )
          .get(),
      )
      .find((url) => url?.includes("trade.tixplus.jp"));
    if (window.startAt && applyURL) {
      const scope = scoped();
      result.candidates.push(
        fact(
          snapshot,
          scope.entityRef,
          "ticket.resale",
          {
            officialName: "公式チケットトレード",
            kind: "resale",
            applyStartAt: window.startAt,
            ...(window.endAt ? { applyEndAt: window.endAt } : {}),
            applyURL,
            cadenceRaw: periodRaw.match(/期間中毎日12時[^。]*。/)?.[0],
          },
          `.p-live-event-detail__content > :nth-child(${resaleSection.index + 1})::section`,
          sectionRaw,
          [resaleSection.heading],
          scope.applicability,
        ),
      );
    }
  }

  const qualificationHeading = $(contentNode)
    .find("h3")
    .filter((_i, node) =>
      /^2\.\s*チケットの転売・譲渡/.test(text($(node).text())),
    )
    .first();
  if (qualificationHeading.length) {
    const box = qualificationHeading.parent();
    const nodes = box.children().toArray();
    const qualificationIndex = nodes.indexOf(qualificationHeading[0]!);
    let end = qualificationIndex + 1;
    while (
      end < nodes.length &&
      !/^h[23]$/.test(
        (nodes[end] as { name?: string }).name?.toLowerCase() ?? "",
      )
    )
      end += 1;
    const raw = text(
      nodes
        .slice(qualificationIndex, end)
        .map((node) => $(node).text())
        .join(" "),
    );
    if (/本人様確認|身分証/.test(raw))
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "ticket.qualificationRaw",
          raw,
          "h3::qualification-resale-transfer",
          raw,
          ["公演に関する注意事項", "チケットの転売・譲渡"],
        ),
      );
  }

  for (const section of h2Sections.filter((entry) =>
    /会場グッズ販売|カプセルトイエリア/.test(entry.heading),
  )) {
    const nodes = sectionNodes(section);
    const sectionRaw = text(nodes.map((node) => $(node).text()).join(" "));
    const locationHeading = nodes.findIndex((node) =>
      /販売場所/.test(text($(node).text())),
    );
    const timeHeading = nodes.findIndex((node) =>
      /販売日時|販売時間/.test(text($(node).text())),
    );
    if (timeHeading < 0) continue;
    const location =
      locationHeading >= 0
        ? text(
            nodes
              .slice(
                locationHeading + 1,
                nextHeadingIndex(nodes, locationHeading),
              )
              .map((node) => $(node).text())
              .join(" "),
          )
        : "";
    const timingRaw = text(
      nodes
        .slice(timeHeading + 1, nextHeadingIndex(nodes, timeHeading))
        .map((node) => $(node).text())
        .join(" "),
    );
    const key = `${sourceKey(snapshot.finalUrl)}#campaign:venue-${section.index}`;
    const requiresTicket =
      /チケットをお持ちでない(?:お客様|方)もご利用いただけます/.test(sectionRaw)
        ? false
        : undefined;
    const scope = scoped();
    result.candidates.push(
      fact(
        snapshot,
        { ...scope.entityRef, sourceKey: key },
        "goods.campaign",
        {
          sourceKey: key,
          officialName: section.heading,
          channel: "venue",
          fulfillment: "venuePickup",
          phase: "during_event",
          ...(location ? { location } : {}),
          ...(requiresTicket !== undefined ? { requiresTicket } : {}),
          url: snapshot.finalUrl,
        },
        `.p-live-event-detail__content > :nth-child(${section.index + 1})::section`,
        sectionRaw,
        [section.heading],
        scope.applicability,
      ),
    );
    for (const [sessionIndex, session] of parseSameDayRanges(
      timingRaw,
    ).entries())
      result.candidates.push(
        fact(
          snapshot,
          scope.entityRef,
          "goods.session",
          {
            campaignSourceKey: key,
            officialName: session.name || section.heading,
            startsAt: session.startsAt,
            endsAt: session.endsAt,
            location,
            ...(requiresTicket !== undefined ? { requiresTicket } : {}),
          },
          `.p-live-event-detail__content > :nth-child(${section.index + 1})::session-${sessionIndex + 1}`,
          timingRaw,
          [section.heading, "販売日時"],
          scope.applicability,
        ),
      );
  }
}

function nextHeadingIndex(nodes: AnyNode[], from: number): number {
  const index = nodes.findIndex(
    (node, candidate) =>
      candidate > from &&
      /^h[2-6]$/.test((node as { name?: string }).name?.toLowerCase() ?? ""),
  );
  return index < 0 ? nodes.length : index;
}

function parseSameDayRanges(
  raw: string,
): { name?: string; startsAt: string; endsAt: string }[] {
  const normalized = raw.normalize("NFKC");
  const date = normalized.match(/(\d{4}年\d{1,2}月\d{1,2}日)/)?.[1];
  if (!date) return [];
  const results: { name?: string; startsAt: string; endsAt: string }[] = [];
  for (const match of normalized.matchAll(
    /(?:[・]\s*([^:：]+)[：:]\s*)?(\d{1,2}:\d{2})\s*[~～]\s*(\d{1,2}:\d{2})/g,
  )) {
    const window = parseJapaneseDateTimeWindow(
      `${date} ${match[2]} ~ ${date} ${match[3]}`,
    );
    if (window.startAt && window.endAt)
      results.push({
        ...(match[1] ? { name: text(match[1]) } : {}),
        startsAt: window.startAt,
        endsAt: window.endAt,
      });
  }
  return results;
}
