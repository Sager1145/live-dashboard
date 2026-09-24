import { lookup as systemLookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { request as httpsRequest } from "node:https";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";
import type { IncomingHttpHeaders, IncomingMessage } from "node:http";
import type {
  FetchOutcome,
  RedirectHop,
  SourcePolicy,
  SourceSnapshot,
} from "./types.js";
import { makeSnapshot } from "./snapshot.js";

const DEFAULT_UA =
  "LiveDashboardCollector/1.0 (+https://github.com/Sager1145/live-dashboard; public-source research collector)";
const blocked = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
] as const)
  blocked.addSubnet(network, prefix, "ipv4");
for (const [network, prefix] of [
  ["::", 128],
  ["::1", 128],
  ["fc00::", 7],
  ["fe80::", 10],
  ["ff00::", 8],
  ["2001:db8::", 32],
] as const)
  blocked.addSubnet(network, prefix, "ipv6");

export type AddressRecord = { address: string; family: 4 | 6 };
export type AddressResolver = (
  hostname: string,
) => Promise<readonly AddressRecord[]>;

export interface FetchDocumentInput {
  url: string;
  sourceDocumentId: string;
  policy: SourcePolicy;
  previousSnapshot?: SourceSnapshot;
  signal?: AbortSignal;
  resolveAddresses?: AddressResolver;
  transport?: FetchTransport;
}

export interface FetchWireResponse {
  statusCode: number;
  headers: IncomingHttpHeaders;
  body: Buffer;
}
export type FetchTransport = (
  url: URL,
  address: AddressRecord,
  policy: SourcePolicy,
  previous: SourceSnapshot | undefined,
  signal: AbortSignal | undefined,
) => Promise<FetchWireResponse>;

export async function fetchDocument(
  input: FetchDocumentInput,
): Promise<FetchOutcome> {
  const policyProblem = validatePolicy(input.policy);
  if (policyProblem)
    return failed("blocked", policyProblem, [], input.previousSnapshot);

  let current = new URL(input.url);
  const redirects: RedirectHop[] = [];
  const maxRedirects = input.policy.maxRedirects ?? 5;
  for (let hop = 0; hop <= maxRedirects; hop += 1) {
    const urlProblem = validateUrl(current, input.policy);
    if (urlProblem)
      return failed("blocked", urlProblem, redirects, input.previousSnapshot);

    let addresses: readonly AddressRecord[];
    try {
      addresses = await (input.resolveAddresses ?? resolvePublicAddresses)(
        current.hostname,
      );
      assertPublicAddresses(addresses);
    } catch (error) {
      return failed(
        "blocked",
        `DNS validation failed: ${errorMessage(error)}`,
        redirects,
        input.previousSnapshot,
      );
    }

    let response: FetchWireResponse;
    try {
      response = await (input.transport ?? requestPinned)(
        current,
        addresses[0]!,
        input.policy,
        hop === 0 ? input.previousSnapshot : undefined,
        input.signal,
      );
    } catch (error) {
      return failed(
        "retryable_failure",
        errorMessage(error),
        redirects,
        input.previousSnapshot,
      );
    }

    if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
      const location = header(response.headers, "location");
      if (!location)
        return failed(
          "blocked",
          "redirect response omitted Location",
          redirects,
          input.previousSnapshot,
          response.statusCode,
        );
      if (hop === maxRedirects)
        return failed(
          "blocked",
          "redirect limit exceeded",
          redirects,
          input.previousSnapshot,
          response.statusCode,
        );
      const next = new URL(location, current);
      const nextProblem = validateUrl(next, input.policy);
      if (nextProblem)
        return failed(
          "blocked",
          `redirect rejected: ${nextProblem}`,
          redirects,
          input.previousSnapshot,
          response.statusCode,
        );
      redirects.push({
        from: current.href,
        to: next.href,
        statusCode: response.statusCode,
      });
      current = next;
      continue;
    }

    if (response.statusCode === 304) {
      if (!input.previousSnapshot)
        return failed(
          "retryable_failure",
          "304 received without a previous snapshot",
          redirects,
          undefined,
          304,
        );
      const checkedAt = new Date().toISOString();
      return {
        status: "unchanged",
        snapshot: input.previousSnapshot,
        validatedAt: checkedAt,
        checkedAt,
      };
    }
    if (response.statusCode === 401 || response.statusCode === 403) {
      return failed(
        "blocked",
        `origin returned ${response.statusCode}; automated retries stopped`,
        redirects,
        input.previousSnapshot,
        response.statusCode,
      );
    }
    if (response.statusCode === 429) {
      return {
        status: "rate_limited",
        statusCode: 429,
        retryAfter: header(response.headers, "retry-after"),
        issue: "origin rate limit reached; schedule after Retry-After",
        lastKnownSnapshot: input.previousSnapshot,
        redirectChain: redirects,
      };
    }
    if (response.statusCode === 404 || response.statusCode === 410) {
      return failed(
        "missing",
        `origin returned ${response.statusCode}; published data must be retained`,
        redirects,
        input.previousSnapshot,
        response.statusCode,
      );
    }
    if (response.statusCode >= 500 || response.statusCode === 408) {
      return failed(
        "retryable_failure",
        `origin returned ${response.statusCode}`,
        redirects,
        input.previousSnapshot,
        response.statusCode,
      );
    }
    if (response.statusCode !== 200) {
      return failed(
        "blocked",
        `unexpected HTTP status ${response.statusCode}`,
        redirects,
        input.previousSnapshot,
        response.statusCode,
      );
    }

    const contentType = (header(response.headers, "content-type") ?? "")
      .split(";", 1)[0]!
      .trim()
      .toLowerCase();
    const allowedTypes = input.policy.contentTypes ?? [
      "text/html",
      "application/xhtml+xml",
    ];
    if (!allowedTypes.includes(contentType))
      return failed(
        "blocked",
        `content type ${contentType || "missing"} is not allowed`,
        redirects,
        input.previousSnapshot,
        200,
      );
    const contentProblem = validateContent(response.body, contentType);
    if (contentProblem)
      return failed(
        "blocked",
        contentProblem,
        redirects,
        input.previousSnapshot,
        200,
      );
    const preview = response.body
      .subarray(0, 16_384)
      .toString("utf8")
      .toLowerCase();
    if (
      /captcha|cloudflare.*challenge|access denied|ログインしてください/.test(
        preview,
      )
    ) {
      return failed(
        "blocked",
        "response appears to be a login, CAPTCHA, or access-denied shell",
        redirects,
        input.previousSnapshot,
        200,
      );
    }

    return {
      status: "snapshotted",
      snapshot: makeSnapshot({
        sourceDocumentId: input.sourceDocumentId,
        fetchUrl: input.url,
        finalUrl: current.href,
        statusCode: 200,
        headers: keepHeaders(response.headers),
        body: response.body,
        redirectChain: redirects,
      }),
    };
  }
  return failed(
    "blocked",
    "redirect limit exceeded",
    redirects,
    input.previousSnapshot,
  );
}

export function validatePolicy(policy: SourcePolicy): string | undefined {
  if (!policy.enabled) return "source is disabled";
  if (policy.reviewStatus !== "approved")
    return `source review status is ${policy.reviewStatus}`;
  if (!policy.robotsCheckedAt) return "robots review is incomplete";
  if (!policy.termsReviewedAt) return "terms review is incomplete";
  if (!policy.host || policy.allowedPaths.length === 0)
    return "source policy has no host/path allowlist";
}

export function validateUrl(
  url: URL,
  policy: SourcePolicy,
): string | undefined {
  if (url.protocol !== "https:") return "only HTTPS is allowed";
  if (url.username || url.password) return "URL userinfo is forbidden";
  if (url.hostname.toLowerCase() !== policy.host.toLowerCase())
    return `host ${url.hostname} is outside policy ${policy.host}`;
  const port = url.port ? Number(url.port) : 443;
  if (!(policy.allowedPorts ?? [443]).includes(port))
    return `port ${port} is not allowed`;
  if (!policy.allowedPaths.some((prefix) => pathMatches(url.pathname, prefix)))
    return `path ${url.pathname} is outside the allowlist`;
}

function pathMatches(path: string, prefix: string): boolean {
  const clean = prefix.startsWith("/") ? prefix : `/${prefix}`;
  if (clean.endsWith("*")) return path.startsWith(clean.slice(0, -1));
  return (
    path === clean || path.startsWith(clean.endsWith("/") ? clean : `${clean}/`)
  );
}

export async function resolvePublicAddresses(
  hostname: string,
): Promise<readonly AddressRecord[]> {
  if (isIP(hostname))
    return [{ address: hostname, family: isIP(hostname) as 4 | 6 }];
  const records = await systemLookup(hostname, { all: true, verbatim: true });
  return records.map(({ address, family }) => ({
    address,
    family: family as 4 | 6,
  }));
}

export function assertPublicAddresses(
  addresses: readonly AddressRecord[],
): void {
  if (addresses.length === 0) throw new Error("host resolved to no addresses");
  for (const record of addresses) {
    if (
      !isIP(record.address) ||
      blocked.check(record.address, record.family === 4 ? "ipv4" : "ipv6")
    )
      throw new Error(`non-public address rejected: ${record.address}`);
    if (record.address.toLowerCase().startsWith("::ffff:"))
      throw new Error(`IPv4-mapped IPv6 address rejected: ${record.address}`);
  }
}

function requestPinned(
  url: URL,
  address: AddressRecord,
  policy: SourcePolicy,
  previous: SourceSnapshot | undefined,
  signal: AbortSignal | undefined,
): Promise<FetchWireResponse> {
  const maxBytes = policy.maxDecompressedBytes ?? 5 * 1024 * 1024;
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {
      "user-agent": policy.userAgent ?? DEFAULT_UA,
      accept: (
        policy.contentTypes ?? ["text/html", "application/xhtml+xml"]
      ).join(", "),
      "accept-language": "ja,en;q=0.5",
      "accept-encoding": "gzip, br, deflate",
    };
    if (previous?.headers.etag)
      headers["if-none-match"] = previous.headers.etag;
    if (previous?.headers["last-modified"])
      headers["if-modified-since"] = previous.headers["last-modified"];
    const request = httpsRequest(
      url,
      {
        method: "GET",
        headers,
        servername: url.hostname,
        rejectUnauthorized: true,
        signal,
        lookup: (_hostname, _options, callback) =>
          callback(null, address.address, address.family),
      },
      (response) => collectResponse(response, maxBytes).then(resolve, reject),
    );
    request.setTimeout(policy.timeoutMs ?? 20_000, () =>
      request.destroy(new Error("request timeout")),
    );
    request.once("error", reject);
    request.end();
  });
}

async function collectResponse(
  response: IncomingMessage,
  maxBytes: number,
): Promise<FetchWireResponse> {
  const encoding = (
    header(response.headers, "content-encoding") ?? "identity"
  ).toLowerCase();
  const stream =
    encoding === "gzip"
      ? response.pipe(createGunzip())
      : encoding === "br"
        ? response.pipe(createBrotliDecompress())
        : encoding === "deflate"
          ? response.pipe(createInflate())
          : response;
  if (!new Set(["identity", "gzip", "br", "deflate", ""]).has(encoding))
    throw new Error(`unsupported content encoding: ${encoding}`);
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of stream) {
    const value = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += value.length;
    if (size > maxBytes) {
      response.destroy();
      throw new Error(`decompressed response exceeds ${maxBytes} bytes`);
    }
    chunks.push(value);
  }
  return {
    statusCode: response.statusCode ?? 0,
    headers: response.headers,
    body: Buffer.concat(chunks),
  };
}

function validateContent(
  body: Buffer,
  contentType: string,
): string | undefined {
  if (body.length === 0) return "empty response body";
  if (contentType === "text/html" || contentType === "application/xhtml+xml") {
    const start = body
      .subarray(0, 4096)
      .toString("utf8")
      .trimStart()
      .toLowerCase();
    if (
      !(
        start.startsWith("<!doctype html") ||
        start.startsWith("<html") ||
        /<(head|body|main|article)[\s>]/.test(start)
      )
    )
      return "HTML content failed magic-byte/markup validation";
  }
}

function header(
  headers: IncomingHttpHeaders,
  name: string,
): string | undefined {
  const value = headers[name];
  return Array.isArray(value) ? value.join(", ") : value;
}

function keepHeaders(headers: IncomingHttpHeaders): Record<string, string> {
  const kept: Record<string, string> = {};
  for (const name of [
    "content-type",
    "content-length",
    "content-encoding",
    "etag",
    "last-modified",
    "cache-control",
    "date",
  ]) {
    const value = header(headers, name);
    if (value !== undefined) kept[name] = value;
  }
  return kept;
}

function failed(
  status: "blocked" | "missing" | "retryable_failure",
  issue: string,
  redirectChain: readonly RedirectHop[],
  lastKnownSnapshot?: SourceSnapshot,
  statusCode?: number,
): FetchOutcome {
  return {
    status,
    issue,
    redirectChain,
    ...(statusCode === undefined ? {} : { statusCode }),
    ...(lastKnownSnapshot ? { lastKnownSnapshot } : {}),
  };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
