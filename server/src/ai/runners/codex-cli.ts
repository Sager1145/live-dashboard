import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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

/** Last agent_message in a Codex JSONL event stream. Earlier events are not the task result. */
export function finalCodexAnswer(stdout: string): string | null {
  let finalText: string | null = null;
  let sawEvent = false;
  for (const line of stdout.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let event: unknown;
    try {
      event = JSON.parse(trimmed);
    } catch {
      continue;
    }
    if (!event || typeof event !== "object") continue;
    const record = event as Record<string, unknown>;
    if (typeof record.type === "string") sawEvent = true;
    if (
      record.type !== "item.completed" ||
      !record.item ||
      typeof record.item !== "object"
    ) {
      continue;
    }
    const item = record.item as Record<string, unknown>;
    if (item.type === "agent_message" && typeof item.text === "string") {
      finalText = item.text;
    }
  }
  if (sawEvent) return finalText;
  const trimmed = stdout.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export class CodexCliProvider implements AiProvider {
  readonly id = "codex" as const;
  private readonly spawnFn: CliSpawn;
  private readonly executable: string;
  private readonly modelConfig: ModelConfig | null;
  private helpText = "";
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
          "CodexCliProvider requires an injected spawn in this slice",
        );
      });
    this.executable = options?.executable ?? "codex";
    this.modelConfig = options?.modelConfig ?? null;
  }

  async probe(): Promise<ProviderCapabilities> {
    const probed = await probeExecutable({
      providerId: "codex",
      executable: this.executable,
      spawn: this.spawnFn,
      modelConfig: this.modelConfig,
      helpArgs: ["exec", "--help"],
      interpretHelp: (helpText) => ({
        structuredOutput: helpHasFlag(helpText, "--output-schema"),
        vision: false,
        models: [],
      }),
    });
    return this.remember(probed);
  }

  async run(input: ProviderRunInput): Promise<RawRunResult> {
    if (!this.capabilities) await this.probe();
    const model = modelArg(this.helpText, this.modelConfig);
    if (!model.ok) return model.failure;
    const prompt = buildTaskPrompt(input.envelope, input.instructions);
    const directory = await mkdtemp(join(tmpdir(), "live-dashboard-codex-"));
    const schemaPath = join(directory, "output-schema.json");
    await writeFile(schemaPath, JSON.stringify(TASK_PATCH_JSON_SCHEMA), "utf8");
    try {
      const invoked = await invokeCli(this.spawnFn, {
        file: this.executable,
        args: [
          "exec",
          "--json",
          "--ephemeral",
          "--skip-git-repo-check",
          "--ignore-user-config",
          "--sandbox",
          "read-only",
          "--output-schema",
          schemaPath,
          ...model.args,
          prompt,
        ],
        shell: false,
        timeoutMs: input.timeoutMs ?? RUN_TIMEOUT_MS,
      });
      this.lastCallAt = new Date().toISOString();
      if (this.capabilities) this.capabilities.lastCallAt = this.lastCallAt;
      if (!invoked.ok) return invoked;
      return { ok: true, stdout: invoked.stdout };
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }

  normalizeResult(
    stdout: string,
  ): { ok: true; text: string } | ReturnType<typeof providerFailure> {
    const text = finalCodexAnswer(stdout);
    if (text == null) {
      return providerFailure(
        "INVALID_OUTPUT",
        "Codex JSONL did not include a final agent message",
      );
    }
    return { ok: true, text };
  }

  private remember(probed: ProbeExecutableResult): ProviderCapabilities {
    this.helpText = probed.helpText;
    probed.capabilities.lastCallAt = this.lastCallAt;
    this.capabilities = probed.capabilities;
    return probed.capabilities;
  }
}

function modelArg(
  helpText: string,
  config: ModelConfig | null,
):
  | { ok: true; args: string[] }
  | { ok: false; failure: ReturnType<typeof providerFailure> } {
  const model = resolveModelName(config);
  if (!model) return { ok: true, args: [] };
  if (!helpHasFlag(helpText, "--model") && !helpHasFlag(helpText, "-m")) {
    return {
      ok: false,
      failure: providerFailure(
        "UNSUPPORTED_MODEL",
        "Installed codex help does not show a model flag",
      ),
    };
  }
  const flag = helpHasFlag(helpText, "--model") ? "--model" : "-m";
  return { ok: true, args: [flag, model] };
}
