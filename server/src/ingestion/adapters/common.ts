import * as cheerio from "cheerio";
import type { AnyNode } from "domhandler";
import type {
  ApplicabilityCandidate,
  CandidateEntityRef,
  CandidateLink,
  FactCandidate,
  FactEvidence,
  MediaCandidate,
  ParseContext,
  ParseIssue,
  ParseResult,
  SectionCoverage,
  SourceSnapshot,
} from "../types.js";

export const PARSER_VERSION = "1.0.0";
export const unresolved = { kind: "unresolved" as const };
export const wholeEvent = { kind: "whole_event" as const };

export function load(snapshot: SourceSnapshot): cheerio.CheerioAPI {
  return cheerio.load(snapshot.body);
}
export function text(value: string): string {
  return value
    .replace(/\u00a0/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}
export function absolute(href: string, base: string): string | undefined {
  if (
    !href ||
    href.startsWith("javascript:") ||
    href.startsWith("mailto:") ||
    href === "#"
  )
    return undefined;
  try {
    return new URL(href, base).href;
  } catch {
    return undefined;
  }
}
export function sourceKey(url: string): string {
  const parsed = new URL(url);
  return `${parsed.hostname}${parsed.pathname}${parsed.search}`;
}
export function evidence(
  locator: string,
  rawText: string,
  sectionPath: readonly string[],
  nearbyHeading?: string,
): FactEvidence {
  return {
    locator,
    rawText: text(rawText),
    sectionPath,
    nearbyHeading,
    sourceLanguage: "ja",
  };
}
export function fact(
  snapshot: SourceSnapshot,
  entityRef: CandidateEntityRef,
  field: string,
  value: unknown,
  locator: string,
  rawText: string,
  sectionPath: readonly string[],
  applicability: ApplicabilityCandidate = unresolved,
): FactCandidate {
  return {
    entityRef,
    field,
    value,
    applicability,
    sourceSnapshotId: snapshot.id,
    evidence: evidence(locator, rawText, sectionPath),
    extractionMethod: "dom",
    parserVersion: PARSER_VERSION,
  };
}
export function media(
  entityRef: CandidateEntityRef,
  url: string,
  purpose: MediaCandidate["purpose"],
  locator: string,
  rawText: string,
  sectionPath: readonly string[],
): MediaCandidate {
  return {
    entityRef,
    url,
    purpose,
    applicability: unresolved,
    evidence: evidence(locator, rawText, sectionPath),
  };
}
export function baseResult(adapterId: string): MutableParseResult {
  return {
    adapterId,
    adapterVersion: PARSER_VERSION,
    candidates: [],
    media: [],
    links: [],
    sections: [],
    issues: [],
  };
}
export interface MutableParseResult {
  adapterId: string;
  adapterVersion: string;
  candidates: FactCandidate[];
  media: MediaCandidate[];
  links: CandidateLink[];
  sections: SectionCoverage[];
  issues: ParseIssue[];
}
export function finish(result: MutableParseResult): ParseResult {
  return result;
}
export function contextRef(
  context: ParseContext,
  fallbackUrl: string,
): CandidateEntityRef {
  return context.entityRef ?? { sourceKey: sourceKey(fallbackUrl) };
}
export function selectedText(
  $: cheerio.CheerioAPI,
  node: AnyNode,
  selector: string,
): string {
  return text($(node).find(selector).first().text());
}
export function uniqueLinks(links: readonly CandidateLink[]): CandidateLink[] {
  const seen = new Set<string>();
  return links.filter((link) => !seen.has(link.url) && !!seen.add(link.url));
}

export interface TicketOfficialLink {
  label: string;
  url: string;
  role: "application" | "overseasApplication" | "support" | "product";
  productNames?: string[];
}

/** Extracts actionable ticket links without losing the product names adjacent to an application URL. */
export function ticketLinksAndProducts(
  $: cheerio.CheerioAPI,
  nodes: readonly AnyNode[],
  baseURL: string,
): { links: TicketOfficialLink[]; lotteryProducts: string[] } {
  type Link = TicketOfficialLink & { localProducts: string[] };
  const products: string[] = [];
  const links: Link[] = [];
  const groupProductContext = nodes.some((node) =>
    /封入|申込券|シリアル|抽選申込券|対象商品/.test(text($(node).text())),
  );
  const addProduct = (value: string) => {
    const name = text(value).replace(/^[/・●○]\s*/, "");
    if (name && !products.includes(name)) products.push(name);
    return name;
  };
  const anchorsIn = (node: AnyNode) =>
    [
      ...($(node).is("a[href]") ? [node] : []),
      ...$(node).find("a[href]").toArray(),
    ].flatMap((anchor) => {
      const resolved = absolute($(anchor).attr("href") ?? "", baseURL);
      return resolved
        ? [{ node: anchor, url: resolved, label: text($(anchor).text()) }]
        : [];
    });
  const productsIn = (node: AnyNode, inheritedProductContext = false) => {
    const raw = text($(node).text());
    const productContext =
      inheritedProductContext ||
      /封入|申込券|シリアル|抽選申込券|対象商品/.test(raw);
    const linked = anchorsIn(node)
      .filter(({ url, label }) =>
        isLotteryProductLink(url, label, productContext),
      )
      .map(({ label }) => addProduct(label));
    const clone = $(node).clone();
    clone.find("br").replaceWith("\n");
    clone.find("p,li,tr,div").append("\n");
    const unlinked = clone
      .text()
      .split(/\n+/)
      .map((line) => lotteryProductFromLine(line, productContext, linked))
      .filter((name): name is string => !!name)
      .map(addProduct);
    return [...linked, ...unlinked].filter(
      (name, index, all) => !!name && all.indexOf(name) === index,
    );
  };

  for (const node of nodes) {
    const raw = text($(node).text());
    const productContext = /封入|申込券|シリアル|抽選申込券|対象商品/.test(raw);
    const anchors = anchorsIn(node);
    productsIn(node, groupProductContext);

    for (const anchor of anchors) {
      const role = ticketLinkRole(anchor.url, anchor.label, productContext);
      if (!role) continue;
      const label = anchor.label || anchor.url;
      let pairedProducts: string[] = [];
      if (role === "application" || role === "overseasApplication") {
        const bounded = $(anchor.node).closest("p,li,tr").first();
        const boundedNode = bounded.toArray()[0] ?? node;
        const boundedApplications = anchorsIn(boundedNode).filter(
          ({ url, label }) => {
            const candidateRole = ticketLinkRole(
              url,
              label,
              /封入|申込券|シリアル|抽選申込券|対象商品/.test(
                text($(boundedNode).text()),
              ),
            );
            return (
              candidateRole === "application" ||
              candidateRole === "overseasApplication"
            );
          },
        );
        const boundedProducts = productsIn(boundedNode);
        const namedProducts = boundedProducts.filter((name) =>
          anchor.label.includes(name),
        );
        if (namedProducts.length) pairedProducts = namedProducts;
        else if (boundedApplications.length === 1)
          pairedProducts = productsIn(boundedNode);
      }
      links.push({
        label,
        url: anchor.url,
        role,
        localProducts: pairedProducts,
      });
    }
  }

  const applicationLinks = links.filter(
    (link) =>
      link.role === "application" || link.role === "overseasApplication",
  );
  if (
    applicationLinks.length === 1 &&
    !applicationLinks[0]!.localProducts.length
  )
    applicationLinks[0]!.localProducts = [...products];

  const merged = new Map<string, TicketOfficialLink>();
  for (const link of links) {
    const key = `${link.role}:${link.url}`;
    const previous = merged.get(key);
    const productNames = [
      ...(previous?.productNames ?? []),
      ...link.localProducts,
    ].filter((name, index, all) => all.indexOf(name) === index);
    merged.set(key, {
      label: previous?.label ?? link.label,
      url: link.url,
      role: link.role,
      ...(productNames.length ? { productNames } : {}),
    });
  }
  return { links: [...merged.values()], lotteryProducts: products };
}

function isLotteryProductLink(
  url: string,
  label: string,
  productContext: boolean,
): boolean {
  const parsed = new URL(url);
  if (ticketVendorRole(parsed.hostname)) return false;
  return (
    /\/(?:discographies|music|cd|bd)\//i.test(parsed.pathname) ||
    (productContext &&
      /「|『|Single|Album|Blu-?ray|シングル|アルバム|CD/i.test(label))
  );
}

function ticketLinkRole(
  url: string,
  label: string,
  productContext: boolean,
): TicketOfficialLink["role"] | undefined {
  const parsed = new URL(url);
  const searchable = `${label} ${url}`;
  if (
    /support|\/qa\/|\/guide\/|faceticket_about|update-dokosha/i.test(searchable)
  )
    return "support";
  const vendorRole = ticketVendorRole(parsed.hostname);
  if (vendorRole) return vendorRole;
  if (isLotteryProductLink(url, label, productContext)) return "product";
  if (
    /受付(?:はこちら|URL)|申込(?:はこちら|URL)|お申し込みはこちら|応募はこちら|\bapply\b/i.test(
      searchable,
    )
  )
    return "application";
  return undefined;
}

function ticketVendorRole(
  hostname: string,
): "application" | "overseasApplication" | undefined {
  if (/^(?:ib\.)eplus\.jp$|kktix|cityline/i.test(hostname))
    return "overseasApplication";
  if (
    /(?:^|\.)eplus\.jp$|(?:^|\.)pia\.jp$|(?:^|\.)l-tike\.com$|(?:^|\.)tixplus\.jp$|^ticket\.bushiroad-music\.com$|^ticket\.rakuten\.co\.jp$|(?:^|\.)ticketport\.jp$/i.test(
      hostname,
    )
  )
    return "application";
  return undefined;
}

function lotteryProductFromLine(
  value: string,
  productContext: boolean,
  linkedProducts: readonly string[],
): string | undefined {
  if (!productContext) return undefined;
  let candidate = linkedProducts
    .reduce((line, linked) => line.replaceAll(linked, ""), text(value))
    .replace(/^[※・●○①-⑳\s]+/, "")
    .replace(/^\d{1,2}月\d{1,2}日[^ ]*リリース\s*/, "")
    .replace(/^\d{4}年\d{1,2}月\d{1,2}日[^ ]*発売\s*/, "")
    .replace(/(?:初回生産分(?:限定)?(?:に)?封入|に封入|封入特典|封入の).*$/, "")
    .trim();
  if (
    !candidate ||
    /^(?:抽選申込券封入商品|最速先行抽選申込券 封入タイトル|商品発売日|申込について)/.test(
      candidate,
    ) ||
    /受付期間|当落発表|入金期間|枚数制限|下記\d+タイトル|ご応募いただけ/.test(
      candidate,
    ) ||
    !/「.+」|『.+』|Single|Album|Blu-?ray|シングル|アルバム|\bCD\b/i.test(
      candidate,
    )
  )
    return undefined;
  return candidate;
}

export interface ParsedSchedule {
  dayLabel?: string;
  localDate: string;
  doorsAt?: string;
  startsAt?: string;
  doorsLocalDate?: string;
  startsLocalDate?: string;
  timeZone: "Asia/Tokyo";
  raw: string;
}

export function parseJapaneseSchedules(raw: string): ParsedSchedule[] {
  const normalized = raw.normalize("NFKC");
  const pattern =
    /(?:(Day\.?\s*\d+|DAY\s*\d+|昼公演|夜公演)\s*[：:]?\s*)?(\d{4})年(\d{1,2})月(\d{1,2})日[^\d]{0,20}(?:(?:開場\s*)?(\d{1,2}):(\d{2})\s*(?:開場)?\s*[／/]\s*(?:開演\s*)?(\d{1,2}):(\d{2})\s*(?:開演)?)?/gi;
  const schedules: ParsedSchedule[] = [];
  for (const match of normalized.matchAll(pattern)) {
    const year = Number(match[2]);
    const month = Number(match[3]);
    const day = Number(match[4]);
    const date = validDate(year, month, day);
    if (!date) continue;
    const doors = normalizeTime(date, match[5], match[6]);
    const starts = normalizeTime(date, match[7], match[8]);
    schedules.push({
      ...(match[1] ? { dayLabel: match[1].replace(/\s+/g, "") } : {}),
      localDate: date,
      ...(doors?.time ? { doorsAt: doors.time } : {}),
      ...(starts?.time ? { startsAt: starts.time } : {}),
      ...(doors && doors.date !== date ? { doorsLocalDate: doors.date } : {}),
      ...(starts && starts.date !== date
        ? { startsLocalDate: starts.date }
        : {}),
      timeZone: "Asia/Tokyo",
      raw: match[0],
    });
  }
  return schedules;
}

function validDate(
  year: number,
  month: number,
  day: number,
): string | undefined {
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  )
    return undefined;
  return `${year.toString().padStart(4, "0")}-${month.toString().padStart(2, "0")}-${day.toString().padStart(2, "0")}`;
}

function normalizeTime(
  date: string,
  rawHour?: string,
  rawMinute?: string,
): { time: string; date: string } | undefined {
  if (rawHour === undefined || rawMinute === undefined) return undefined;
  const hour = Number(rawHour);
  const minute = Number(rawMinute);
  if (
    minute < 0 ||
    minute > 59 ||
    hour < 0 ||
    hour > 24 ||
    (hour === 24 && minute !== 0)
  )
    return undefined;
  if (hour < 24)
    return {
      time: `${hour.toString().padStart(2, "0")}:${minute.toString().padStart(2, "0")}`,
      date,
    };
  const next = new Date(`${date}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + 1);
  return { time: "00:00", date: next.toISOString().slice(0, 10) };
}

export interface ParsedDateTimeWindow {
  startAt?: string;
  endAt?: string;
  raw: string;
}

export function parseJapaneseDateTimeWindow(
  raw: string,
  marker?: string,
): ParsedDateTimeWindow {
  const normalized = raw.normalize("NFKC");
  const start = marker ? normalized.indexOf(marker.normalize("NFKC")) : 0;
  if (start < 0) return { raw };
  const tail = normalized.slice(start + (marker?.length ?? 0));
  const boundary = tail.search(
    /(?:当落発表|入金期間|支払(?:い)?期間|配信期間|【[^】]+】|■(?!受付))/,
  );
  const fragment = boundary > 0 ? tail.slice(0, boundary) : tail;
  const values = parseJapaneseDateTimes(fragment);
  return {
    ...(values[0] ? { startAt: values[0] } : {}),
    ...(values[1] ? { endAt: values[1] } : {}),
    raw: text(fragment).replace(/^[:：]\s*/, ""),
  };
}

export function parseJapaneseDateTime(
  raw: string,
  marker?: string,
): string | undefined {
  const normalized = raw.normalize("NFKC");
  const start = marker ? normalized.indexOf(marker.normalize("NFKC")) : 0;
  if (start < 0) return undefined;
  return parseJapaneseDateTimes(
    normalized.slice(start + (marker?.length ?? 0)),
  )[0];
}

function parseJapaneseDateTimes(raw: string): string[] {
  const matches = [
    ...raw.matchAll(
      /(?:(?:(\d{4})年)?(\d{1,2})月(\d{1,2})日|(?:(\d{4})\/)?(\d{1,2})\/(\d{1,2}))(?:\([^)]*\))?\s*(\d{1,2})(?::|時)(\d{2})(?:分)?/g,
    ),
  ];
  const values: string[] = [];
  let contextYear: number | undefined;
  for (const match of matches) {
    const explicitYear = match[1] ?? match[4];
    if (explicitYear) contextYear = Number(explicitYear);
    if (!contextYear) continue;
    const month = Number(match[2] ?? match[5]);
    const day = Number(match[3] ?? match[6]);
    const date = validDate(contextYear, month, day);
    if (!date) continue;
    const time = normalizeTime(date, match[7], match[8]);
    if (time) values.push(`${time.date}T${time.time}:00+09:00`);
  }
  return values;
}
