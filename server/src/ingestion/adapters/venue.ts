import type { SourceAdapter } from "../types.js";
import {
  baseResult,
  contextRef,
  fact,
  finish,
  load,
  parseJapaneseSchedules,
  PARSER_VERSION,
  sourceKey,
  text,
  wholeEvent,
} from "./common.js";

export const tachikawaVenueEventAdapter: SourceAdapter = {
  id: "venue.tachikawa-event",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const url = new URL(snapshot.finalUrl);
    const matched =
      url.hostname === "www.t-sg.jp" &&
      url.pathname.startsWith("/events/") &&
      $("#wrapper.event-details h1.ttl-style3").length === 1 &&
      $("table tr").length > 0;
    return {
      matched,
      reason: matched
        ? "verified Tachikawa event detail table"
        : "missing Tachikawa event detail structure",
    };
  },
  discover() {
    return [];
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
    const title = text($("#wrapper.event-details h1.ttl-style3").text());
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.officialTitle",
          title,
          "#wrapper.event-details h1.ttl-style3",
          title,
          ["header"],
          wholeEvent,
        ),
      );
    const rows = $("table tr");
    const row = (label: string) =>
      rows
        .filter((_i, node) => text($(node).find("th").text()) === label)
        .first();
    const scheduleRow = row("公演日時");
    const scheduleRaw = text(scheduleRow.text());
    for (const schedule of parseJapaneseSchedules(scheduleRaw)) {
      const value = { ...schedule, dayLabel: "single" };
      const performanceId = context.performanceRefs?.single;
      const entityRef = performanceId
        ? { ...ref, performanceId }
        : {
            ...ref,
            sourceKey: `${sourceKey(snapshot.finalUrl)}#performance:single`,
          };
      result.candidates.push(
        fact(
          snapshot,
          entityRef,
          "performance.schedule",
          value,
          "table tr:has(th:contains('公演日時'))",
          scheduleRaw,
          ["概要", "公演日時"],
          performanceId
            ? { kind: "performances", performanceIds: [performanceId] }
            : { kind: "unresolved", rawText: "single" },
        ),
      );
    }
    const venueEvidence = text(
      $("header img[alt*='TACHIKAWA STAGE GARDEN']").first().attr("alt") ??
        $("meta[property='og:description']").attr("content") ??
        "",
    );
    if (venueEvidence)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "performance.venueRaw",
          "TACHIKAWA STAGE GARDEN",
          "header img[alt*='TACHIKAWA STAGE GARDEN']",
          venueEvidence,
          ["venue"],
        ),
      );
    const performerRaw = text(row("出演者").text());
    const performers = text(row("出演者").find("td").text());
    if (performers)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "performance.performers",
          [performers],
          "table tr:has(th:contains('出演者'))",
          performerRaw,
          ["概要", "出演者"],
        ),
      );
    const priceRaw = text(row("料金").text());
    const tiers = [...priceRaw.matchAll(/＜([^＞]+)＞\s*([\d,]+)円/g)].map(
      (match) => ({
        name: text(match[1]!),
        amount: Number(match[2]!.replaceAll(",", "")),
        currency: "JPY",
        priceKind: "full",
        raw: match[0],
      }),
    );
    if (tiers.length)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "ticket.tiers",
          tiers,
          "table tr:has(th:contains('料金'))",
          priceRaw,
          ["概要", "料金"],
        ),
      );
    result.sections.push({ name: "概要", locator: "table", status: "parsed" });
    return finish(result);
  },
};
