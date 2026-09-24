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

/** Gemini `--output-format json` may wrap the answer in a string field named response. */
export function unwrapGeminiResponse(stdout: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return stdout.trim();
  }
  if (
    parsed &&
    typeof parsed === "object" &&
    !Array.isArray(parsed) &&
    typeof (parsed as { response?: unknown }).response === "string"
  ) {
    return (parsed as { response: string }).response;
  }
  return JSON.stringify(parsed);
}

export class GeminiCliProvider implements AiProvider {
  readonly id = "gemini" as const;
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
          "GeminiCliProvider requires an injected spawn in this slice",
        );
      });
    this.executable = options?.executable ?? "gemini";
    this.modelConfig = options?.modelConfig ?? null;
  }

  async probe(): Promise<ProviderCapabilities> {
    const probed = await probeExecutable({
      providerId: "gemini",
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
    const model = configuredModelArgs(
      this.helpText,
      this.modelConfig,
      "gemini",
    );
    if (!model.ok) return model.failure;
    const prompt = buildTaskPrompt(input.envelope, input.instructions);
    const args = ["-p", prompt, ...model.args];
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
      return { ok: true as const, text: stdout.trim() };
    }
    try {
      return { ok: true as const, text: unwrapGeminiResponse(stdout) };
    } catch {
      return providerFailure(
        "INVALID_OUTPUT",
        "Gemini output could not be unwrapped",
      );
    }
  }
}
