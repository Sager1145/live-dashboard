import { createHash } from "node:crypto";
import type { RedirectHop, SourceSnapshot } from "./types.js";

export function normalizeDocumentText(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/[\t ]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function sha256(value: Buffer | string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function makeSnapshot(input: {
  sourceDocumentId: string;
  fetchUrl: string;
  finalUrl: string;
  statusCode: number;
  headers: Readonly<Record<string, string>>;
  fetchedAt?: string;
  body: Buffer;
  redirectChain?: readonly RedirectHop[];
}): SourceSnapshot {
  const text = input.body.toString("utf8");
  const rawSha256 = sha256(input.body);
  const fetchedAt = input.fetchedAt ?? new Date().toISOString();
  return {
    id: `sha256:${rawSha256}`,
    sourceDocumentId: input.sourceDocumentId,
    fetchUrl: input.fetchUrl,
    finalUrl: input.finalUrl,
    statusCode: input.statusCode,
    headers: input.headers,
    fetchedAt,
    body: input.body,
    text,
    rawSha256,
    normalizedSha256: sha256(normalizeDocumentText(text)),
    redirectChain: input.redirectChain ?? [],
  };
}
