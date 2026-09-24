import {
  providerFailure,
  type CliSpawn,
  type LoginMethod,
  type ProviderCapabilities,
  type ProviderFailure,
  type ProviderId,
} from "./provider.js";
import { resolveMaxContext, type ModelConfig } from "./model-policy.js";

const PROBE_TIMEOUT_MS = 15_000;

export interface ProbeInterpretation {
  structuredOutput: boolean;
  vision: boolean;
  models: string[];
}

export interface ProbeExecutableOptions {
  providerId: ProviderId;
  executable: string;
  spawn: CliSpawn;
  platform?: NodeJS.Platform;
  arch?: NodeJS.Architecture;
  modelConfig?: ModelConfig | null;
  mayBillExtra?: boolean;
  loginMethod?: LoginMethod;
  versionArgs?: string[];
  helpArgs?: string[];
  interpretHelp?: (helpText: string) => ProbeInterpretation;
}

export interface ProbeExecutableResult {
  capabilities: ProviderCapabilities;
  helpText: string;
  versionText: string;
  failure?: ProviderFailure;
}

function assertProbeArgs(args: string[]): void {
  for (const arg of args) {
    if (
      arg.length > 64 ||
      /[<>]|https?:|token|secret|cookie|password/i.test(arg)
    ) {
      throw new Error("capability probe refused a non-version argument");
    }
  }
}

function unavailable(options: ProbeExecutableOptions): ProviderCapabilities {
  const os = options.platform ?? process.platform;
  const arch = options.arch ?? process.arch;
  return {
    providerId: options.providerId,
    cliVersion: null,
    os,
    arch,
    loginMethod: options.loginMethod ?? "official_cli",
    probedModels: [],
    structuredOutput: false,
    vision: false,
    maxContext: resolveMaxContext(options.modelConfig),
    health: "unavailable",
    lastCallAt: null,
    mayBillExtra: options.mayBillExtra ?? true,
    platformSupported: false,
    quotaRemaining: "unknown",
  };
}

/**
 * Version and help only. Does not start login, open a browser, or forward page text.
 * `os`/`arch` are the process that ran the probe, so darwin is never reported as linux.
 */
export async function probeExecutable(
  options: ProbeExecutableOptions,
): Promise<ProbeExecutableResult> {
  const os = options.platform ?? process.platform;
  const arch = options.arch ?? process.arch;
  const versionArgs = options.versionArgs ?? ["--version"];
  const helpArgs = options.helpArgs ?? ["--help"];
  assertProbeArgs(versionArgs);
  assertProbeArgs(helpArgs);

  let version: Awaited<ReturnType<CliSpawn>>;
  try {
    version = await options.spawn({
      file: options.executable,
      args: versionArgs,
      shell: false,
      timeoutMs: PROBE_TIMEOUT_MS,
    });
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return {
        capabilities: unavailable(options),
        helpText: "",
        versionText: "",
      };
    }
    throw error;
  }
  if (version.errorCode === "ENOENT") {
    return {
      capabilities: unavailable(options),
      helpText: "",
      versionText: "",
      failure: providerFailure(
        "UNSUPPORTED_PLATFORM",
        `${options.executable} is not installed`,
      ),
    };
  }

  let helpText = "";
  try {
    const help = await options.spawn({
      file: options.executable,
      args: helpArgs,
      shell: false,
      timeoutMs: PROBE_TIMEOUT_MS,
    });
    if (help.errorCode === "ENOENT") {
      return {
        capabilities: unavailable(options),
        helpText: "",
        versionText: "",
      };
    }
    helpText = help.stdout || help.stderr;
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === "ENOENT") {
      return {
        capabilities: unavailable(options),
        helpText: "",
        versionText: "",
      };
    }
    throw error;
  }

  const interpreted = options.interpretHelp?.(helpText) ?? {
    structuredOutput: false,
    vision: false,
    models: [],
  };
  const versionText = (version.stdout || version.stderr).trim();
  const cliVersion = versionText.split(/\r?\n/, 1)[0]?.trim() || null;
  const launched = version.exitCode === 0 || versionText.length > 0;
  return {
    capabilities: {
      providerId: options.providerId,
      cliVersion,
      os,
      arch,
      loginMethod: options.loginMethod ?? "official_cli",
      probedModels: interpreted.models,
      structuredOutput: interpreted.structuredOutput,
      vision: interpreted.vision,
      maxContext: resolveMaxContext(options.modelConfig),
      health: launched ? "healthy" : "unavailable",
      lastCallAt: null,
      mayBillExtra: options.mayBillExtra ?? true,
      platformSupported: launched,
      quotaRemaining: "unknown",
    },
    helpText,
    versionText,
  };
}

export function helpHasFlag(helpText: string, flag: string): boolean {
  const escaped = flag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(?:^|\\s)${escaped}(?:\\s|=|,|$)`, "m").test(helpText);
}
