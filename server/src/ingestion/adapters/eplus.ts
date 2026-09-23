import type { SourceAdapter } from "../types.js";
import {
  absolute,
  baseResult,
  contextRef,
  fact,
  finish,
  load,
  parseJapaneseDateTimeWindow,
  PARSER_VERSION,
  sourceKey,
  text,
  wholeEvent,
} from "./common.js";

export const eplusEventDetailAdapter: SourceAdapter = {
  id: "eplus.event-detail",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const url = new URL(snapshot.finalUrl);
    const matched =
      url.hostname === "eplus.jp" &&
      url.pathname.startsWith("/sf/detail/") &&
      $(".block-ticket-article").length > 0;
    return {
      matched,
      reason: matched
        ? "verified e+ ticket article template"
        : "missing e+ ticket article blocks",
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
    const title = text($("h1.s4-main-title").first().text()).replace(
      /のチケット情報$/,
      "",
    );
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "event.officialTitle",
          title,
          "h1.s4-main-title",
          title,
          ["header"],
          wholeEvent,
        ),
      );

    $(".block-ticket-article").each((articleIndex, article) => {
      const heading = text($(article).find("h3").first().text());
      const dayLabel = heading
        .match(/DAY\s*(\d+)/i)?.[0]
        ?.replace(/\s+/g, "")
        .toUpperCase();
      if (!dayLabel) {
        result.issues.push({
          code: "unresolved_scope",
          message: "e+ ticket article has no explicit DAY label",
          locator: `.block-ticket-article:nth-of-type(${articleIndex + 1}) h3`,
          severity: "warning",
        });
        return;
      }
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
      result.sections.push({
        name: dayLabel,
        locator: `.block-ticket-article:nth-of-type(${articleIndex + 1})`,
        status: "parsed",
      });

      $(article)
        .find(".block-ticket")
        .each((ticketIndex, ticket) => {
          const raw = text($(ticket).text());
          const window = parseJapaneseDateTimeWindow(raw, "受付期間");
          if (!window.startAt) return;
          const label = text($(ticket).find(".label-ticket").first().text());
          const roundTitle = text(
            $(ticket).find(".block-ticket__title").first().text(),
          );
          const officialName = roundTitle || label || "受付";
          const onclick =
            $(ticket)
              .find("button[onclick*='window.location.href']")
              .first()
              .attr("onclick") ?? "";
          const orderUrl = onclick.match(
            /window\.location\.href='(https:\/\/[^']+)'/,
          )?.[1];
          const applyURL =
            absolute(orderUrl ?? "", snapshot.finalUrl) ?? snapshot.finalUrl;
          result.candidates.push(
            fact(
              snapshot,
              performanceRef,
              "ticket.round",
              {
                officialName,
                kind: /先着/.test(`${label} ${roundTitle}`)
                  ? "first_come"
                  : "lottery",
                dayLabel,
                applyStartAt: window.startAt,
                ...(window.endAt ? { applyEndAt: window.endAt } : {}),
                applyURL,
                windowRaw: window.raw,
              },
              `.block-ticket-article:nth-of-type(${articleIndex + 1}) .block-ticket:nth-of-type(${ticketIndex + 1})`,
              raw,
              ["チケット一覧", dayLabel, officialName],
              applicability,
            ),
          );
        });
    });
    return finish(result);
  },
};
