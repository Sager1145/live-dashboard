import * as http2 from "node:http2";
import { sign } from "node:crypto";

import { buildNotificationPayload } from "./payload.js";
import type { ApnsMessage, ApnsSendResult } from "./types.js";

export interface ApnsCredentials {
  readonly teamID?: string;
  readonly keyID?: string;
  readonly privateKey?: string;
  readonly topic?: string;
}

export interface ApnsTransportOptions {
  readonly environment: "development" | "production";
  readonly credentials: ApnsCredentials;
  readonly maxAttempts?: number;
  readonly tokenLifetimeMs?: number;
  readonly baseBackoffMs?: number;
  readonly maxBackoffMs?: number;
  readonly requestTimeoutMs?: number;
}

export interface ApnsRequest {
  readonly origin: string;
  readonly path: string;
  readonly headers: Readonly<Record<string, string | number>>;
  readonly body: string;
  readonly timeoutMs: number;
}

export interface ApnsResponse {
  readonly status: number;
  readonly headers: Readonly<Record<string, string | string[] | undefined>>;
  readonly body: string;
}

export type ApnsRequestExecutor = (
  request: ApnsRequest,
) => Promise<ApnsResponse>;

export interface ApnsTransportDependencies {
  readonly execute?: ApnsRequestExecutor;
  readonly now?: () => Date;
  readonly sleep?: (milliseconds: number) => Promise<void>;
  /** Returns a number in [0, 1); injected to make retry tests deterministic. */
  readonly random?: () => number;
}

interface ProviderToken {
  readonly value: string;
  readonly issuedAtMs: number;
}

const TRANSIENT_STATUS = new Set([429, 500, 503]);
const INVALID_TOKEN_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);
const TOKEN_REASONS = new Set(["ExpiredProviderToken", "InvalidProviderToken"]);

export class ApnsTransport {
  readonly #options: Required<Omit<ApnsTransportOptions, "credentials">> & {
    readonly credentials: ApnsCredentials;
  };
  readonly #execute: ApnsRequestExecutor;
  readonly #now: () => Date;
  readonly #sleep: (milliseconds: number) => Promise<void>;
  readonly #random: () => number;
  #providerToken: ProviderToken | null = null;

  constructor(
    options: ApnsTransportOptions,
    dependencies: ApnsTransportDependencies = {},
  ) {
    this.#options = {
      ...options,
      maxAttempts: options.maxAttempts ?? 3,
      tokenLifetimeMs: options.tokenLifetimeMs ?? 50 * 60_000,
      baseBackoffMs: options.baseBackoffMs ?? 500,
      maxBackoffMs: options.maxBackoffMs ?? 5 * 60_000,
      requestTimeoutMs: options.requestTimeoutMs ?? 10_000,
    };
    if (
      !Number.isInteger(this.#options.maxAttempts) ||
      this.#options.maxAttempts < 1
    ) {
      throw new RangeError("maxAttempts must be a positive integer");
    }
    if (
      this.#options.tokenLifetimeMs <= 0 ||
      this.#options.tokenLifetimeMs >= 60 * 60_000
    ) {
      throw new RangeError(
        "tokenLifetimeMs must be positive and less than one hour",
      );
    }
    if (
      !Number.isSafeInteger(this.#options.requestTimeoutMs) ||
      this.#options.requestTimeoutMs < 1
    ) {
      throw new RangeError("requestTimeoutMs must be a positive safe integer");
    }
    this.#execute = dependencies.execute ?? executeHttp2Request;
    this.#now = dependencies.now ?? (() => new Date());
    this.#sleep =
      dependencies.sleep ??
      ((milliseconds) =>
        new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.#random = dependencies.random ?? Math.random;
  }

  async send(message: ApnsMessage): Promise<ApnsSendResult> {
    const credentialError = validateCredentials(this.#options.credentials);
    if (credentialError)
      return { outcome: "failed", reason: credentialError, attempts: 0 };
    if (!/^[a-fA-F0-9]{64}$/.test(message.deviceToken)) {
      return {
        outcome: "invalid_token",
        reason: "MalformedDeviceToken",
        attempts: 0,
      };
    }
    if (!Number.isFinite(message.expiration.getTime())) {
      return { outcome: "failed", reason: "InvalidExpiration", attempts: 0 };
    }
    if (
      !message.collapseID ||
      Buffer.byteLength(message.collapseID, "utf8") > 64
    ) {
      return { outcome: "failed", reason: "InvalidCollapseID", attempts: 0 };
    }

    try {
      this.#getProviderToken(
        this.#options.credentials as Required<ApnsCredentials>,
      );
    } catch {
      return {
        outcome: "failed",
        reason: "InvalidApnsPrivateKey",
        attempts: 0,
      };
    }

    const payload = JSON.stringify(
      buildNotificationPayload(message.notification),
    );
    if (Buffer.byteLength(payload, "utf8") > 4_096) {
      return { outcome: "failed", reason: "PayloadTooLarge", attempts: 0 };
    }

    let lastReason = "TransientFailure";
    let retryAfterMs = this.#options.baseBackoffMs;
    for (let attempt = 1; attempt <= this.#options.maxAttempts; attempt += 1) {
      try {
        const response = await this.#execute(
          this.#makeRequest(message, payload),
        );
        const reason = parseReason(response.body);
        if (response.status === 200) {
          const apnsID = firstHeader(response.headers["apns-id"]);
          return apnsID
            ? { outcome: "sent", apnsID, attempts: attempt }
            : { outcome: "sent", attempts: attempt };
        }
        if (INVALID_TOKEN_REASONS.has(reason)) {
          const invalidatedAt = parseInvalidatedAt(response.body);
          return invalidatedAt
            ? {
                outcome: "invalid_token",
                reason,
                attempts: attempt,
                invalidatedAt,
              }
            : { outcome: "invalid_token", reason, attempts: attempt };
        }
        if (TOKEN_REASONS.has(reason) && attempt < this.#options.maxAttempts) {
          this.#providerToken = null;
          lastReason = reason;
          continue;
        }
        if (!TRANSIENT_STATUS.has(response.status)) {
          return {
            outcome: "failed",
            reason,
            attempts: attempt,
            status: response.status,
          };
        }
        lastReason = reason;
        retryAfterMs = this.#retryDelay(
          response.headers["retry-after"],
          attempt,
        );
      } catch (error) {
        lastReason =
          error instanceof Error ? error.message : "APNsNetworkError";
        retryAfterMs = this.#retryDelay(undefined, attempt);
      }

      if (attempt < this.#options.maxAttempts) await this.#sleep(retryAfterMs);
    }
    return {
      outcome: "retry",
      reason: lastReason,
      attempts: this.#options.maxAttempts,
      retryAfterMs,
    };
  }

  #makeRequest(message: ApnsMessage, body: string): ApnsRequest {
    const credentials = this.#options.credentials as Required<ApnsCredentials>;
    const expiration = Math.max(
      0,
      Math.floor(message.expiration.getTime() / 1_000),
    );
    return {
      origin:
        this.#options.environment === "production"
          ? "https://api.push.apple.com"
          : "https://api.sandbox.push.apple.com",
      path: `/3/device/${message.deviceToken}`,
      headers: {
        authorization: `bearer ${this.#getProviderToken(credentials)}`,
        "apns-topic": credentials.topic,
        "apns-push-type": "alert",
        "apns-expiration": expiration,
        "apns-priority": message.priority ?? 10,
        "apns-collapse-id": message.collapseID,
        "content-type": "application/json",
      },
      body,
      timeoutMs: this.#options.requestTimeoutMs,
    };
  }

  #getProviderToken(credentials: Required<ApnsCredentials>): string {
    const nowMs = this.#now().getTime();
    if (
      this.#providerToken &&
      nowMs - this.#providerToken.issuedAtMs < this.#options.tokenLifetimeMs
    ) {
      return this.#providerToken.value;
    }
    const encodedHeader = encodeJson({ alg: "ES256", kid: credentials.keyID });
    const encodedClaims = encodeJson({
      iss: credentials.teamID,
      iat: Math.floor(nowMs / 1_000),
    });
    const signingInput = `${encodedHeader}.${encodedClaims}`;
    const signature = sign("sha256", Buffer.from(signingInput), {
      key: credentials.privateKey,
      dsaEncoding: "ieee-p1363",
    }).toString("base64url");
    const value = `${signingInput}.${signature}`;
    this.#providerToken = { value, issuedAtMs: nowMs };
    return value;
  }

  #retryDelay(header: string | string[] | undefined, attempt: number): number {
    const parsed = parseRetryAfter(header, this.#now());
    if (parsed !== null) return Math.min(parsed, this.#options.maxBackoffMs);
    const exponential = Math.min(
      this.#options.baseBackoffMs * 2 ** (attempt - 1),
      this.#options.maxBackoffMs,
    );
    return Math.max(0, Math.floor(exponential * (0.5 + this.#random() * 0.5)));
  }
}

export function parseRetryAfter(
  value: string | string[] | undefined,
  now: Date,
): number | null {
  const raw = Array.isArray(value) ? value[0] : value;
  if (!raw) return null;
  if (/^\d+$/.test(raw.trim())) return Number(raw.trim()) * 1_000;
  const date = new Date(raw);
  return Number.isFinite(date.getTime())
    ? Math.max(0, date.getTime() - now.getTime())
    : null;
}

function encodeJson(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function validateCredentials(credentials: ApnsCredentials): string | null {
  if (!credentials.teamID) return "MissingApnsTeamID";
  if (!credentials.keyID) return "MissingApnsKeyID";
  if (!credentials.privateKey) return "MissingApnsPrivateKey";
  if (!credentials.topic) return "MissingApnsTopic";
  return null;
}

function parseReason(body: string): string {
  try {
    const parsed = JSON.parse(body) as { reason?: unknown };
    return typeof parsed.reason === "string"
      ? parsed.reason
      : "UnknownApnsError";
  } catch {
    return "UnknownApnsError";
  }
}

function parseInvalidatedAt(body: string): string | undefined {
  try {
    const parsed = JSON.parse(body) as { timestamp?: unknown };
    if (typeof parsed.timestamp !== "number") return undefined;
    return new Date(parsed.timestamp * 1_000).toISOString();
  } catch {
    return undefined;
  }
}

function firstHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

async function executeHttp2Request(
  request: ApnsRequest,
): Promise<ApnsResponse> {
  return await new Promise<ApnsResponse>((resolve, reject) => {
    const session = http2.connect(request.origin);
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      session.close();
      if (error) reject(error);
    };
    session.once("error", finish);

    const stream = session.request({
      [http2.constants.HTTP2_HEADER_METHOD]: "POST",
      [http2.constants.HTTP2_HEADER_PATH]: request.path,
      ...request.headers,
    });
    let status = 0;
    let responseHeaders: Record<string, string | string[] | undefined> = {};
    const chunks: Buffer[] = [];
    stream.setEncoding("utf8");
    stream.on("response", (headers) => {
      status = Number(headers[http2.constants.HTTP2_HEADER_STATUS] ?? 0);
      responseHeaders = Object.fromEntries(
        Object.entries(headers)
          .filter(([name]) => name !== http2.constants.HTTP2_HEADER_STATUS)
          .map(([name, value]) => [
            name,
            value === undefined
              ? undefined
              : Array.isArray(value)
                ? value.map(String)
                : String(value),
          ]),
      );
    });
    stream.on("data", (chunk: string) => chunks.push(Buffer.from(chunk)));
    stream.setTimeout(request.timeoutMs, () => {
      stream.close(http2.constants.NGHTTP2_CANCEL);
      finish(new Error("APNsRequestTimeout"));
    });
    stream.once("error", finish);
    stream.once("end", () => {
      if (settled) return;
      settled = true;
      session.close();
      resolve({
        status,
        headers: responseHeaders,
        body: Buffer.concat(chunks).toString("utf8"),
      });
    });
    stream.end(request.body);
  });
}
