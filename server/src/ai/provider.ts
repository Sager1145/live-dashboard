import { spawn } from "node:child_process";
import type { BudgetPolicy } from "./budget-policy.js";
import {
  validateModelOutput,
  type ValidationResult,
} from "./result-validator.js";
import type { TaskEnvelope } from "./task-envelope.js";

export const PROVIDER_IDS = [
  "codex",
  "claude",
  "gemini",
  "grok",
  "api",
] as const;
export type ProviderId = (typeof PROVIDER_IDS)[number];

export const PROVIDER_ERROR_CODES = [
  "AUTH_REQUIRED",
  "QUOTA_EXHAUSTED",
  "RATE_LIMITED",
  "UNSUPPORTED_MODEL",
  "UNSUPPORTED_PLATFORM",
  "INVALID_OUTPUT",
  "TIMEOUT",
] as const;
export type ProviderErrorCode = (typeof PROVIDER_ERROR_CODES)[number];

/** No official remaining-quota API is consulted. Never a fabricated percent. */
export type QuotaRemaining = "unknown";

export type ProviderHealth =
  | "unknown"
  | "healthy"
  | "unavailable"
  | "auth_required"
  | "quota_exhausted"
  | "rate_limited";

export type LoginMethod = "official_cli" | "api_key" | "none" | "unknown";

export interface ProviderCapabilities {
  providerId: ProviderId;
  cliVersion: string | null;
  os: NodeJS.Platform;
  arch: NodeJS.Architecture;
  loginMethod: LoginMethod;
  probedModels: string[];
  structuredOutput: boolean;
  vision: boolean;
  maxContext: number | null;
  health: ProviderHealth;
  lastCallAt: string | null;
  mayBillExtra: boolean;
  platformSupported: boolean;
  quotaRemaining: QuotaRemaining;
}

export interface ProviderFailure {
  ok: false;
  code: ProviderErrorCode;
  message: string;
  quotaRemaining: QuotaRemaining;
  retryAfterMs: number | null;
  review?: "fact_conflict";
}

export function providerFailure(
  code: ProviderErrorCode,
  message: string,
  retryAfterMs: number | null = null,
): ProviderFailure {
  return {
    ok: false,
    code,
    message,
    quotaRemaining: "unknown",
    retryAfterMs,
  };
}

export interface CliSpawnRequest {
  file: string;
  args: string[];
  shell: false;
  timeoutMs: number;
}

export interface CliSpawnResult {
  stdout: string;
  stderr: string;
  exitCode: number | null;
  errorCode?: string | null;
  timedOut?: boolean;
}

export type CliSpawn = (request: CliSpawnRequest) => Promise<CliSpawnResult>;

const SENSITIVE_ENV =
  /(?:^|_)(?:TOKEN|SECRET|PASSWORD|COOKIE|CREDENTIAL|API_KEY|AUTH_TOKEN)(?:_|$)|(?:^|_)KEY$/i;

/** Child env for the CLI binary only. This process never reads auth files. */
export function cliChildEnv(source: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(source)) {
    if (value === undefined) continue;
    if (SENSITIVE_ENV.test(key)) continue;
    env[key] = value;
  }
  return env;
}

export function defaultCliSpawn(
  request: CliSpawnRequest,
): Promise<CliSpawnResult> {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result: CliSpawnResult) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    const child = spawn(request.file, request.args, {
      shell: false,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: cliChildEnv(process.env),
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout?.on("data", (chunk: Buffer | string) => {
      stdout.push(Buffer.from(chunk));
    });
    child.stderr?.on("data", (chunk: Buffer | string) => {
      stderr.push(Buffer.from(chunk));
    });
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
        exitCode: null,
        errorCode: null,
        timedOut: true,
      });
    }, request.timeoutMs);
    child.on("error", (error: NodeJS.ErrnoException) => {
      clearTimeout(timer);
      finish({
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: error.message,
        exitCode: null,
        errorCode: error.code ?? "SPAWN_ERROR",
        timedOut: false,
      });
    });
    child.on("close", (exitCode) => {
      clearTimeout(timer);
      finish({
        stdout: Buffer.concat(stdout).toString("utf8"),
        stderr: Buffer.concat(stderr).toString("utf8"),
        exitCode,
        errorCode: null,
        timedOut: false,
      });
    });
  });
}

export function classifyCliOutput(
  stderr: string,
  stdout: string,
  exitCode: number | null,
): ProviderFailure | null {
  if (exitCode === 0) return null;
  const text = `${stderr}\n${stdout}`;
  if (/\b429\b|rate limit|too many requests/i.test(text)) {
    return providerFailure("RATE_LIMITED", "CLI reported a rate limit");
  }
  if (
    /quota exceeded|usage limit|insufficient quota|credit balance is too low|out of (?:extra )?usage/i.test(
      text,
    )
  ) {
    return providerFailure("QUOTA_EXHAUSTED", "CLI reported exhausted quota");
  }
  if (
    /\b401\b|not logged in|please (?:log|sign) in|authentication required|login required|unauthorized|auth(?:entication)? (?:failed|expired|required)/i.test(
      text,
    )
  ) {
    return providerFailure("AUTH_REQUIRED", "CLI requires official login");
  }
  if (
    /unsupported model|unknown model|model .* not (?:found|available|supported)/i.test(
      text,
    )
  ) {
    return providerFailure(
      "UNSUPPORTED_MODEL",
      "CLI rejected the configured model",
    );
  }
  if (exitCode === null) {
    return providerFailure("INVALID_OUTPUT", "CLI produced no exit status");
  }
  return providerFailure("INVALID_OUTPUT", `CLI exited ${exitCode}`);
}

export async function invokeCli(
  spawnFn: CliSpawn,
  request: CliSpawnRequest,
): Promise<
  | { ok: true; stdout: string; stderr: string; exitCode: number | null }
  | ProviderFailure
> {
  let result: CliSpawnResult;
  try {
    result = await spawnFn({ ...request, shell: false });
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return providerFailure(
        "UNSUPPORTED_PLATFORM",
        `${request.file} is not installed`,
      );
    }
    throw error;
  }
  if (result.errorCode === "ENOENT") {
    return providerFailure(
      "UNSUPPORTED_PLATFORM",
      `${request.file} is not installed`,
    );
  }
  if (result.timedOut) {
    return providerFailure("TIMEOUT", `${request.file} timed out`);
  }
  const failure = classifyCliOutput(
    result.stderr,
    result.stdout,
    result.exitCode,
  );
  if (failure) return failure;
  return {
    ok: true,
    stdout: result.stdout,
    stderr: result.stderr,
    exitCode: result.exitCode,
  };
}

export interface ProviderRunInput {
  envelope: TaskEnvelope;
  instructions: string;
  timeoutMs?: number;
}

export type RawRunResult = { ok: true; stdout: string } | ProviderFailure;

export interface AiProvider {
  readonly id: ProviderId;
  probe(): Promise<ProviderCapabilities>;
  run(input: ProviderRunInput): Promise<RawRunResult>;
  normalizeResult(stdout: string): { ok: true; text: string } | ProviderFailure;
}

export type BoundedTaskResult = ValidationResult | ProviderFailure;

/**
 * probe → run → normalizeResult → one Zod validation.
 * Not referenced by the fetch worker or HTTP API.
 */
export async function runBoundedTask(
  provider: AiProvider,
  input: ProviderRunInput,
  budget: BudgetPolicy,
  repair?: (text: string) => string | Promise<string>,
): Promise<BoundedTaskResult> {
  const gate = budget.tryAcquire(provider.id);
  if (!gate.ok) return gate;
  try {
    const capabilities = await provider.probe();
    if (
      !capabilities.platformSupported ||
      capabilities.health === "unavailable"
    ) {
      const failure = providerFailure(
        "UNSUPPORTED_PLATFORM",
        `${provider.id} is unavailable on ${capabilities.os}/${capabilities.arch}`,
      );
      budget.observe(provider.id, failure.code);
      return failure;
    }
    const run = await provider.run(input);
    if (!run.ok) {
      budget.observe(provider.id, run.code);
      return run;
    }
    const normalized = provider.normalizeResult(run.stdout);
    if (!normalized.ok) {
      budget.observe(provider.id, normalized.code);
      return normalized;
    }
    const validated = await validateModelOutput({
      text: normalized.text,
      envelope: input.envelope,
      repair,
    });
    if (!validated.ok) budget.observe(provider.id, validated.code);
    return validated;
  } finally {
    budget.release(provider.id);
  }
}
