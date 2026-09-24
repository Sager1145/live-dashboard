import * as cheerio from "cheerio";
import type { AnyNode, Element } from "domhandler";
import { text } from "./adapters/common.js";
import { sha256 } from "./snapshot.js";
import type { ParseResult, SourceSnapshot } from "./types.js";

const SKIP = new Set(["script", "style", "noscript", "template"]);
const INLINE = new Set([
  "a",
  "abbr",
  "b",
  "br",
  "cite",
  "code",
  "em",
  "i",
  "img",
  "small",
  "span",
  "strong",
  "sub",
  "sup",
  "time",
  "wbr",
]);

export interface SectionLink {
  id: string;
  label: string;
  href: string;
}

export interface SectionImage {
  id: string;
  alt: string | null;
  src: string;
}

/** Parent heading text is visible, so the child task hash can move with that scope. */
export interface ResolvedBlockDependency {
  status: "resolved";
  parentScopeHash: string;
  identityTableVersion: string;
  dependencyHash: string;
}

/** No parent heading was visible. Performance ids are not invented to fill the gap. */
export interface UnresolvedBlockDependency {
  status: "unresolved";
  reason: "parent_scope_not_visible";
}

export type BlockDependency = ResolvedBlockDependency | UnresolvedBlockDependency;

export interface SectionBlock {
  blockID: string;
  contentHash: string;
  parentBlockID: string | null;
  parentHeading: string | null;
  headingPath: readonly string[];
  domPath: string;
  sourceOrder: number;
  anchor: string | null;
  kind: "heading" | "list" | "table" | "table-row" | "content";
  text: string;
  links: readonly SectionLink[];
  images: readonly SectionImage[];
  dependency: BlockDependency;
}

export interface SectionGraph {
  /** Hash of performances and stops already present on the parser result. */
  identityTableVersion: string;
  blocks: readonly SectionBlock[];
}

interface IdentityRow {
  field: string;
  sourceKey: string | null;
  performanceId: string | null;
  stopId: string | null;
  applicability: unknown;
  value: unknown;
}

interface Frame {
  level: number;
  title: string;
  blockID: string;
}

interface BuildState {
  $: cheerio.CheerioAPI;
  snapshot: SourceSnapshot;
  identityVersion: string;
  blocks: SectionBlock[];
  stack: Frame[];
  ordinals: Map<string, number>;
}

/** Stable JSON so the same parser facts always produce the same version. */
export function canonicalJSON(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(",")}]`;
  if (value && typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJSON(record[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value) ?? "null";
}

/**
 * Identity version is only parser output.
 * Missing performance or stop ids stay null; this function never allocates them.
 */
export function identityTableFromParse(parsed: ParseResult): {
  version: string;
  performances: readonly IdentityRow[];
  stops: readonly IdentityRow[];
} {
  const performances = parsed.candidates
    .filter((candidate) => candidate.field === "performance.schedule")
    .map((candidate) => ({
      field: candidate.field,
      sourceKey: candidate.entityRef.sourceKey ?? null,
      performanceId: candidate.entityRef.performanceId ?? null,
      stopId: null,
      applicability: candidate.applicability,
      value: candidate.value,
    }));
  const stops = parsed.candidates
    .filter(
      (candidate) =>
        candidate.field.startsWith("stop.") ||
        candidate.applicability.kind === "stop",
    )
    .map((candidate) => ({
      field: candidate.field,
      sourceKey: candidate.entityRef.sourceKey ?? null,
      performanceId: candidate.entityRef.performanceId ?? null,
      stopId:
        candidate.applicability.kind === "stop"
          ? (candidate.applicability.stopId ?? null)
          : null,
      applicability: candidate.applicability,
      value: candidate.value,
    }));
  return {
    version: sha256(`identity\u001f${canonicalJSON({ performances, stops })}`),
    performances,
    stops,
  };
}

export function buildSectionGraph(
  snapshot: SourceSnapshot,
  parsed: ParseResult,
): SectionGraph {
  const identity = identityTableFromParse(parsed);
  const $ = cheerio.load(snapshot.body);
  const root = rootElement($);
  const state: BuildState = {
    $,
    snapshot,
    identityVersion: identity.version,
    blocks: [],
    stack: [],
    ordinals: new Map(),
  };
  if (root) emit(state, root);
  return { identityTableVersion: identity.version, blocks: state.blocks };
}

function rootElement($: cheerio.CheerioAPI): Element | null {
  const selected = $("main").first();
  const main = selected.get(0);
  if (main && main.type === "tag") return main;
  const article = $("article").first().get(0);
  if (article && article.type === "tag") return article;
  const body = $("body").first().get(0);
  if (body && body.type === "tag") return body;
  const root = $.root().children().get(0);
  return root && root.type === "tag" ? root : null;
}

function tags(el: Element): Element[] {
  return (el.children ?? []).filter(
    (node): node is Element =>
      node.type === "tag" && !SKIP.has(node.name.toLowerCase()),
  );
}

function isHeading(el: Element): boolean {
  return /^h[1-3]$/.test(el.name.toLowerCase());
}

function emit(state: BuildState, el: Element): void {
  const name = el.name.toLowerCase();
  if (SKIP.has(name)) return;
  if (isHeading(el)) {
    emitHeading(state, el);
    return;
  }
  if (name === "ul" || name === "ol") {
    emitLeaf(state, el, "list");
    return;
  }
  if (name === "table") {
    emitTable(state, el);
    return;
  }
  const kids = tags(el);
  const structural = kids.filter(
    (kid) => !INLINE.has(kid.name.toLowerCase()),
  );
  if (structural.length === 0) {
    emitLeaf(state, el, "content");
    return;
  }
  if (structural.length === 1 && kids.length === 1) {
    emit(state, structural[0]!);
    return;
  }
  for (const kid of kids) {
    const name = kid.name.toLowerCase();
    if (INLINE.has(name) && name !== "img") continue;
    emit(state, kid);
  }
}

function emitHeading(state: BuildState, el: Element): void {
  const title = text(state.$(el).text());
  if (!title) return;
  const level = Number(el.name[1]);
  while (state.stack.length && state.stack.at(-1)!.level >= level)
    state.stack.pop();
  const parent = state.stack.at(-1) ?? null;
  const anchor = anchorOf(el);
  const ordinal = takeOrdinal(
    state,
    `heading:${parent?.blockID ?? "root"}:${level}:${anchor ?? ""}`,
  );
  const blockID = makeBlockID(state.snapshot, [
    "heading",
    parent?.blockID ?? "root",
    String(level),
    anchor ?? "",
    String(ordinal),
  ]);
  pushBlock(state, {
    blockID,
    parent,
    kind: "heading",
    anchor,
    text: title,
    element: el,
    headingTitle: title,
  });
  state.stack.push({ level, title, blockID });
}

function emitTable(state: BuildState, el: Element): void {
  const rows = tableRows(state.$, el);
  const header = rows[0]?.every((cell) => cell.header) ? rows[0] : null;
  const data = header ? rows.slice(1) : rows;
  if (!header || data.length === 0) {
    emitLeaf(state, el, "table");
    return;
  }
  const headers = header.map((cell) => cell.text);
  data.forEach((row, index) => {
    const parent = state.stack.at(-1) ?? null;
    const rowKey = row[0]?.text ?? "";
    const ordinal = takeOrdinal(
      state,
      `row:${parent?.blockID ?? "root"}:${headers.join("|")}:${rowKey}`,
    );
    const anchor = rowAnchor(row);
    const blockID = makeBlockID(state.snapshot, [
      "table-row",
      parent?.blockID ?? "root",
      headers.join("|"),
      rowKey,
      anchor ?? "",
      String(ordinal),
    ]);
    const repeated = headers
      .map((label, cell) => `${label}: ${row[cell]?.text ?? ""}`.trim())
      .join("\n");
    pushBlock(state, {
      blockID,
      parent,
      kind: "table-row",
      anchor,
      text: repeated,
      element: rowElement(el, index, state.$),
      headingTitle: null,
    });
  });
}

function emitLeaf(
  state: BuildState,
  el: Element,
  kind: "list" | "table" | "content",
): void {
  const parent = state.stack.at(-1) ?? null;
  const anchor = anchorOf(el);
  const ordinal = takeOrdinal(
    state,
    `${kind}:${parent?.blockID ?? "root"}:${anchor ?? ""}`,
  );
  const blockID = makeBlockID(state.snapshot, [
    kind,
    parent?.blockID ?? "root",
    anchor ?? "",
    String(ordinal),
  ]);
  pushBlock(state, {
    blockID,
    parent,
    kind,
    anchor,
    text: text(state.$(el).text()),
    element: el,
    headingTitle: null,
  });
}

function pushBlock(
  state: BuildState,
  input: {
    blockID: string;
    parent: Frame | null;
    kind: SectionBlock["kind"];
    anchor: string | null;
    text: string;
    element: Element;
    headingTitle: string | null;
  },
): void {
  const links = collectLinks(
    state.$,
    input.element,
    input.blockID,
    state.snapshot.finalUrl,
  );
  const images = collectImages(
    state.$,
    input.element,
    input.blockID,
    state.snapshot.finalUrl,
  );
  const normalized = text(input.text);
  if (!normalized && links.length === 0 && images.length === 0) return;
  const headingPath = [
    ...state.stack.map((frame) => frame.title),
    ...(input.headingTitle ? [input.headingTitle] : []),
  ];
  const parentTitles = state.stack.map((frame) => frame.title);
  state.blocks.push({
    blockID: input.blockID,
    contentHash: sha256(
      `content\u001f${canonicalJSON({
        text: normalized,
        links: links.map((link) => ({ href: link.href, label: link.label })),
        images: images.map((image) => ({ src: image.src, alt: image.alt })),
      })}`,
    ),
    parentBlockID: input.parent?.blockID ?? null,
    parentHeading: parentTitles.at(-1) ?? null,
    headingPath,
    domPath: domPath(input.element),
    sourceOrder: state.blocks.length,
    anchor: input.anchor,
    kind: input.kind,
    text: normalized,
    links,
    images,
    dependency: dependencyFor(parentTitles, state.identityVersion),
  });
}

export function dependencyFor(
  parentTitles: readonly string[],
  identityTableVersion: string,
): BlockDependency {
  if (parentTitles.length === 0 || parentTitles.every((title) => !title))
    return { status: "unresolved", reason: "parent_scope_not_visible" };
  const parentScopeHash = sha256(`scope\u001f${parentTitles.join("\u001f")}`);
  return {
    status: "resolved",
    parentScopeHash,
    identityTableVersion,
    dependencyHash: sha256(
      `dependency\u001f${parentScopeHash}\u001f${identityTableVersion}`,
    ),
  };
}

function takeOrdinal(state: BuildState, key: string): number {
  const next = state.ordinals.get(key) ?? 0;
  state.ordinals.set(key, next + 1);
  return next;
}

function makeBlockID(snapshot: SourceSnapshot, parts: readonly string[]): string {
  return `block-${sha256([snapshot.sourceDocumentId, ...parts].join("\u001f")).slice(0, 32)}`;
}

function anchorOf(el: Element): string | null {
  const id = el.attribs?.id?.trim();
  return id ? id : null;
}

function collectLinks(
  $: cheerio.CheerioAPI,
  el: Element,
  blockID: string,
  base: string,
): SectionLink[] {
  const nodes: Element[] = [];
  if (el.name.toLowerCase() === "a" && el.attribs?.href) nodes.push(el);
  $(el)
    .find("a[href]")
    .each((_, node) => {
      if (node.type === "tag") nodes.push(node);
    });
  const links: SectionLink[] = [];
  for (const node of nodes) {
    const raw = node.attribs?.href?.trim() ?? "";
    if (
      !raw ||
      raw.startsWith("#") ||
      /^javascript:/i.test(raw) ||
      raw.startsWith("mailto:")
    )
      continue;
    let href = raw;
    try {
      href = new URL(raw, base).href;
    } catch {
      href = raw;
    }
    links.push({
      id: `${blockID}:link:${sha256(href).slice(0, 12)}:${links.length}`,
      label: text($(node).text()),
      href,
    });
  }
  return links;
}

function collectImages(
  $: cheerio.CheerioAPI,
  el: Element,
  blockID: string,
  base: string,
): SectionImage[] {
  const nodes: Element[] = [];
  if (el.name.toLowerCase() === "img") nodes.push(el);
  $(el)
    .find("img")
    .each((_, node) => {
      if (node.type === "tag") nodes.push(node);
    });
  const images: SectionImage[] = [];
  const seen = new Set<string>();
  for (const node of nodes) {
    const raw = (
      node.attribs?.src ||
      node.attribs?.["data-src"] ||
      ""
    ).trim();
    if (!raw) continue;
    let src = raw;
    try {
      src = new URL(raw, base).href;
    } catch {
      src = raw;
    }
    if (seen.has(src)) continue;
    seen.add(src);
    const alt = node.attribs?.alt?.trim() || null;
    images.push({
      id: `${blockID}:image:${sha256(src).slice(0, 12)}:${images.length}`,
      alt,
      src,
    });
  }
  return images;
}

interface TableCell {
  text: string;
  header: boolean;
  id: string | null;
}

function tableRows($: cheerio.CheerioAPI, table: Element): TableCell[][] {
  const rows: TableCell[][] = [];
  $(table)
    .find("> tr, > thead > tr, > tbody > tr, > tfoot > tr")
    .each((_, node) => {
      if (node.type !== "tag") return;
      const cells: TableCell[] = [];
      $(node)
        .children("th, td")
        .each((__, cell) => {
          if (cell.type !== "tag") return;
          cells.push({
            text: text($(cell).text()),
            header: cell.name.toLowerCase() === "th",
            id: cell.attribs?.id?.trim() || null,
          });
        });
      if (cells.some((cell) => cell.text)) rows.push(cells);
    });
  return rows;
}

function rowAnchor(row: readonly TableCell[]): string | null {
  return row.find((cell) => cell.id)?.id ?? null;
}

function rowElement(
  table: Element,
  dataIndex: number,
  $: cheerio.CheerioAPI,
): Element {
  const rows: Element[] = [];
  $(table)
    .find("> tr, > thead > tr, > tbody > tr, > tfoot > tr")
    .each((_, node) => {
      if (node.type === "tag") rows.push(node);
    });
  // Data index follows the header row, which is the first row when headers exist.
  return rows[dataIndex + 1] ?? rows[dataIndex] ?? table;
}

function domPath(el: Element): string {
  const parts: string[] = [];
  let current: Element | null = el;
  while (current) {
    const tag = current.name.toLowerCase();
    if (tag === "html") break;
    const parent: AnyNode | null = current.parent;
    let index = 1;
    if (parent && "children" in parent) {
      const siblings = parent.children.filter(
        (node): node is Element => node.type === "tag" && node.name === current!.name,
      );
      const at = siblings.indexOf(current);
      index = at >= 0 ? at + 1 : 1;
    }
    const id = current.attribs?.id ? `#${current.attribs.id}` : "";
    parts.push(`${tag}${id}:nth-of-type(${index})`);
    current = parent && parent.type === "tag" ? parent : null;
  }
  return parts.reverse().join(" > ");
}
