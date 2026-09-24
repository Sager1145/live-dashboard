import {
  helpHasFlag,
  probeExecutable,
  type ProbeExecutableResult,
} from "../capability-probe.js";
import { resolveModelName, type ModelConfig } from "../model-policy.js";
import {
  invokeCli,
  providerFailure,
  type AiProvider,
  type CliSpawn,
  type ProviderCapabilities,
  type ProviderRunInput,
  type RawRunResult,
} from "../provider.js";
import { TASK_PATCH_JSON_SCHEMA } from "../result-validator.js";
import { buildTaskPrompt } from "../task-envelope.js";

const RUN_TIMEOUT_MS = 120_000;

/**
 * Official structured-output flag only. `--json-schema` is used when help text
 * shows it. `--output-format` is not treated as a schema flag by itself.
 */
export function claudeStructuredOutputFlag(
  helpText: string,
): "--json-schema" | null {
  if (helpHasFlag(helpText, "--json-schema")) return "--json-schema";
  return null;
}

export function normalizeClaudeOutput(
  stdout: string,
  structuredOutput: boolean,
): { ok: true; text: string } | ReturnType<typeof providerFailure> {
  const trimmed = stdout.trim();
  if (!structuredOutput) return { ok: true, text: trimmed };
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return providerFailure(
      "INVALID_OUTPUT",
      "Claude structured output was not JSON",
    );
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { ok: true, text: trimmed };
  }
  const record = parsed as Record<string, unknown>;
  if (record.structured_output != null) {
    return {
      ok: true,
      text:
        typeof record.structured_output === "string"
          ? record.structured_output
          : JSON.stringify(record.structured_output),
    };
  }
  if (typeof record.result === "string")
    return { ok: true, text: record.result };
  return { ok: true, text: trimmed };
}

export class ClaudeCodeCliProvider implements AiProvider {
  readonly id = "claude" as const;
  private readonly spawnFn: CliSpawn;
  private readonly executable: string;
  private readonly modelConfig: ModelConfig | null;
  private helpText = "";
  private structuredOutput = false;
  private lastCallAt: string | null = null;
  private capabilities: ProviderCapabilities | null = null;

  constructor(options?: {
    spawn?: CliSpawn;
    executable?: string;
    modelConfig?: ModelConfig | null;
  }) {
    this.spawnFn = options?.spawn ?? missingSpawn("claude");
    this.executable = options?.executable ?? "claude";
    this.modelConfig = options?.modelConfig ?? null;
  }

  async probe(): Promise<ProviderCapabilities> {
    const probed = await probeExecutable({
      providerId: "claude",
      executable: this.executable,
      spawn: this.spawnFn,
      modelConfig: this.modelConfig,
      interpretHelp: (helpText) => ({
        structuredOutput: claudeStructuredOutputFlag(helpText) !== null,
        vision: false,
        models: [],
      }),
    });
    this.helpText = probed.helpText;
    this.structuredOutput = probed.capabilities.structuredOutput;
    return this.remember(probed);
  }

  async run(input: ProviderRunInput): Promise<RawRunResult> {
    if (!this.capabilities) await this.probe();
    const model = configuredModelArgs(
      this.helpText,
      this.modelConfig,
      "claude",
    );
    if (!model.ok) return model.failure;
    const prompt = buildTaskPrompt(input.envelope, input.instructions);
    const args = ["-p", prompt, ...model.args];
    const schemaFlag = claudeStructuredOutputFlag(this.helpText);
    if (schemaFlag) {
      if (helpHasFlag(this.helpText, "--output-format")) {
        args.push("--output-format", "json");
      }
      args.push(schemaFlag, JSON.stringify(TASK_PATCH_JSON_SCHEMA));
    }
    const invoked = await invokeCli(this.spawnFn, {
      file: this.executable,
      args,
      shell: false,
      timeoutMs: input.timeoutMs ?? RUN_TIMEOUT_MS,
    });
    this.touch();
    if (!invoked.ok) return invoked;
    return { ok: true, stdout: invoked.stdout };
  }

  normalizeResult(stdout: string) {
    return normalizeClaudeOutput(stdout, this.structuredOutput);
  }

  private touch(): void {
    this.lastCallAt = new Date().toISOString();
    if (this.capabilities) this.capabilities.lastCallAt = this.lastCallAt;
  }

  private remember(probed: ProbeExecutableResult): ProviderCapabilities {
    probed.capabilities.lastCallAt = this.lastCallAt;
    this.capabilities = probed.capabilities;
    return probed.capabilities;
  }
}

function missingSpawn(file: string): CliSpawn {
  return async () => {
    throw new Error(
      `${file} provider requires an injected spawn in this slice`,
    );
  };
}

export function configuredModelArgs(
  helpText: string,
  config: ModelConfig | null,
  providerName: string,
):
  | { ok: true; args: string[] }
  | { ok: false; failure: ReturnType<typeof providerFailure> } {
  const model = resolveModelName(config);
  if (!model) return { ok: true, args: [] };
  if (helpHasFlag(helpText, "--model"))
    return { ok: true, args: ["--model", model] };
  if (helpHasFlag(helpText, "-m")) return { ok: true, args: ["-m", model] };
  return {
    ok: false,
    failure: providerFailure(
      "UNSUPPORTED_MODEL",
      `Installed ${providerName} help does not show a model flag`,
    ),
  };
}
