export type ReviewStatus = "pending_review" | "approved" | "rejected";

export interface SourcePolicy {
  id: string;
  enabled: boolean;
  reviewStatus: ReviewStatus;
  robotsCheckedAt?: string;
  termsReviewedAt?: string;
  host: string;
  allowedPaths: readonly string[];
  methods?: readonly ("GET" | "HEAD")[];
  contentTypes?: readonly string[];
  allowedPorts?: readonly number[];
  timeoutMs?: number;
  maxDecompressedBytes?: number;
  maxRedirects?: number;
  userAgent?: string;
}

export interface SourceSnapshot {
  id: string;
  sourceDocumentId: string;
  fetchUrl: string;
  finalUrl: string;
  statusCode: number;
  headers: Readonly<Record<string, string>>;
  fetchedAt: string;
  body: Buffer;
  text: string;
  rawSha256: string;
  normalizedSha256: string;
  redirectChain: readonly RedirectHop[];
}

export interface RedirectHop {
  from: string;
  to: string;
  statusCode: number;
}

export type FetchOutcome =
  | { status: "snapshotted"; snapshot: SourceSnapshot }
  | { status: "unchanged"; snapshot: SourceSnapshot; validatedAt: string }
  | {
      status: "blocked" | "rate_limited" | "missing" | "retryable_failure";
      statusCode?: number;
      retryAfter?: string;
      issue: string;
      lastKnownSnapshot?: SourceSnapshot;
      redirectChain: readonly RedirectHop[];
    };

export interface CandidateEntityRef {
  eventId?: string;
  performanceId?: string;
  sourceKey?: string;
}

export interface ApplicabilityCandidate {
  kind: "whole_event" | "performances" | "stop" | "unresolved";
  performanceIds?: readonly string[];
  stopId?: string;
  rawText?: string;
}

export interface FactEvidence {
  sectionPath: readonly string[];
  locator: string;
  rawText: string;
  nearbyHeading?: string;
  sourceLanguage: string;
}

export interface FactCandidate {
  entityRef: CandidateEntityRef;
  field: string;
  value: unknown;
  applicability: ApplicabilityCandidate;
  sourceSnapshotId: string;
  evidence: FactEvidence;
  extractionMethod: "dom" | "structured_data" | "pdf_text" | "manual";
  parserVersion: string;
}

export interface MediaCandidate {
  entityRef: CandidateEntityRef;
  url: string;
  purpose:
    | "key_visual"
    | "goods_list"
    | "product"
    | "event_seating_map"
    | "venue_generic_seating_map"
    | "unknown";
  applicability: ApplicabilityCandidate;
  evidence: FactEvidence;
}

export interface CandidateLink {
  url: string;
  title?: string;
  role:
    | "event"
    | "news"
    | "ticket"
    | "goods"
    | "product"
    | "redirect"
    | "unknown";
  sourceKey?: string;
}

export interface SectionCoverage {
  name: string;
  locator: string;
  status: "parsed" | "empty" | "unsupported";
}

export interface ParseIssue {
  code:
    | "unknown_template"
    | "missing_main_content"
    | "empty_content"
    | "unresolved_scope"
    | "unsupported_section"
    | "invalid_value"
    | "redirect_shell";
  message: string;
  locator?: string;
  severity: "warning" | "error";
}

export interface ParseContext {
  entityRef?: CandidateEntityRef;
  performanceRefs?: Readonly<Record<string, string>>;
}

export interface ParseResult {
  adapterId?: string;
  adapterVersion?: string;
  candidates: readonly FactCandidate[];
  media: readonly MediaCandidate[];
  links: readonly CandidateLink[];
  sections: readonly SectionCoverage[];
  issues: readonly ParseIssue[];
}

export interface MatchDecision {
  matched: boolean;
  reason: string;
}

export interface SourceAdapter {
  readonly id: string;
  readonly version: string;
  matches(snapshot: SourceSnapshot): MatchDecision;
  discover(snapshot: SourceSnapshot): readonly CandidateLink[];
  extract(snapshot: SourceSnapshot, context: ParseContext): ParseResult;
}
