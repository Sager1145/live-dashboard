import type {
  ParseContext,
  ParseResult,
  SourceAdapter,
  SourceSnapshot,
} from "./types.js";
import {
  bangDreamDetailAdapter,
  bangDreamIndexAdapter,
  bushiroadLiveArticleAdapter,
  bushiroadLiveIndexAdapter,
  bushiroadStorePageAdapter,
  eplusEventDetailAdapter,
  loveLiveBranchIndexAdapter,
  loveLiveDetailAdapter,
  loveLiveNewsAdapter,
  schoolIdolStoreAdapter,
  tachikawaVenueEventAdapter,
} from "./adapters/index.js";

export const adapters: readonly SourceAdapter[] = [
  bangDreamIndexAdapter,
  bangDreamDetailAdapter,
  loveLiveNewsAdapter,
  loveLiveBranchIndexAdapter,
  loveLiveDetailAdapter,
  bushiroadLiveIndexAdapter,
  bushiroadLiveArticleAdapter,
  bushiroadStorePageAdapter,
  schoolIdolStoreAdapter,
  eplusEventDetailAdapter,
  tachikawaVenueEventAdapter,
];

export function parseSnapshot(
  snapshot: SourceSnapshot,
  context: ParseContext & { adapterId?: string } = {},
): ParseResult {
  if (context.adapterId) {
    const selected = adapters.find(
      (adapter) => adapter.id === context.adapterId,
    );
    if (!selected)
      return unknown(
        `configured adapter ${context.adapterId} is not registered`,
      );
    const decision = selected.matches(snapshot);
    if (!decision.matched)
      return unknown(`${selected.id} rejected snapshot: ${decision.reason}`);
    return selected.extract(snapshot, context);
  }
  const matches = adapters.filter(
    (adapter) => adapter.matches(snapshot).matched,
  );
  if (matches.length !== 1)
    return unknown(
      matches.length === 0
        ? "no registered adapter matched this template"
        : `ambiguous template matched: ${matches.map((adapter) => adapter.id).join(", ")}`,
    );
  return matches[0]!.extract(snapshot, context);
}

function unknown(message: string): ParseResult {
  return {
    candidates: [],
    media: [],
    links: [],
    sections: [],
    issues: [{ code: "unknown_template", message, severity: "error" }],
  };
}
