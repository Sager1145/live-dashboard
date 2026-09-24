import { helpHasFlag, probeExecutable } from "../capability-probe.js";
import type { ModelConfig } from "../model-policy.js";
import {
  invokeCli,
  providerFailure,
  type AiProvider,
  type CliSpawn,
  type ProviderCapabilities,
  type ProviderRunInput,
  type RawRunResult,
} from "../provider.js";
import { buildTaskPrompt } from "../task-envelope.js";
import { configuredModelArgs } from "./claude-code-cli.js";

const RUN_TIMEOUT_MS = 120_000;

/**
 * One JSON object, not Codex JSONL. `item.completed` / `agent_message` are not read.
 */
export function unwrapGrokEnvelope(
  stdout: string,
): { ok: true; text: string } | ReturnType<typeof providerFailure> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout.trim());
  } catch {
    return providerFailure(
      "INVALID_OUTPUT",
      "Grok output is not a JSON envelope",
    );
  }
  return { ok: true, text: grokEnvelopeText(parsed) };
}

function grokEnvelopeText(parsed: unknown): string {
  if (typeof parsed === "string") return parsed;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return JSON.stringify(parsed);
  }
  const record = parsed as Record<string, unknown>;
  if (typeof record.response === "string") return record.response;
  if (record.response && typeof record.response === "object") {
    return JSON.stringify(record.response);
  }
  if (typeof record.result === "string") return record.result;
  if (typeof record.message === "string") return record.message;
  if (record.message && typeof record.message === "object") {
    const content = (record.message as { content?: unknown }).content;
    if (typeof content === "string") return content;
  }
  return JSON.stringify(parsed);
}

export class GrokBuildCliProvider implements AiProvider {
  readonly id = "grok" as const;
  private readonly spawnFn: CliSpawn;
  private readonly executable: string;
  private readonly modelConfig: ModelConfig | null;
  private helpText = "";
  private jsonOutput = false;
  private lastCallAt: string | null = null;
  private capabilities: ProviderCapabilities | null = null;

  constructor(options?: {
    spawn?: CliSpawn;
    executable?: string;
    modelConfig?: ModelConfig | null;
  }) {
    this.spawnFn =
      options?.spawn ??
      (async () => {
        throw new Error(
          "GrokBuildCliProvider requires an injected spawn in this slice",
        );
      });
    this.executable = options?.executable ?? "grok";
    this.modelConfig = options?.modelConfig ?? null;
  }

  async probe(): Promise<ProviderCapabilities> {
    const probed = await probeExecutable({
      providerId: "grok",
      executable: this.executable,
      spawn: this.spawnFn,
      modelConfig: this.modelConfig,
      interpretHelp: (helpText) => ({
        structuredOutput: helpHasFlag(helpText, "--output-format"),
        vision: false,
        models: [],
      }),
    });
    this.helpText = probed.helpText;
    this.jsonOutput = probed.capabilities.structuredOutput;
    probed.capabilities.lastCallAt = this.lastCallAt;
    this.capabilities = probed.capabilities;
    return probed.capabilities;
  }

  async run(input: ProviderRunInput): Promise<RawRunResult> {
    if (!this.capabilities) await this.probe();
    const model = configuredModelArgs(this.helpText, this.modelConfig, "grok");
    if (!model.ok) return model.failure;
    const prompt = buildTaskPrompt(input.envelope, input.instructions);
    const args = ["-p", prompt, ...model.args];
    if (helpHasFlag(this.helpText, "--no-auto-update")) {
      args.unshift("--no-auto-update");
    }
    if (this.jsonOutput && helpHasFlag(this.helpText, "--output-format")) {
      args.push("--output-format", "json");
    }
    const invoked = await invokeCli(this.spawnFn, {
      file: this.executable,
      args,
      shell: false,
      timeoutMs: input.timeoutMs ?? RUN_TIMEOUT_MS,
    });
    this.lastCallAt = new Date().toISOString();
    if (this.capabilities) this.capabilities.lastCallAt = this.lastCallAt;
    if (!invoked.ok) return invoked;
    return { ok: true, stdout: invoked.stdout };
  }

  normalizeResult(stdout: string) {
    if (!this.jsonOutput) {
      const trimmed = stdout.trim();
      try {
        JSON.parse(trimmed);
        return unwrapGrokEnvelope(trimmed);
      } catch {
        return { ok: true as const, text: trimmed };
      }
    }
    return unwrapGrokEnvelope(stdout);
  }
}
