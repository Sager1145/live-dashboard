import type { ModelConfig } from "./model-policy.js";
import {
  defaultCliSpawn,
  type AiProvider,
  type CliSpawn,
  type ProviderId,
} from "./provider.js";
import { ApiProvider } from "./runners/api-provider.js";
import { ClaudeCodeCliProvider } from "./runners/claude-code-cli.js";
import { CodexCliProvider } from "./runners/codex-cli.js";
import { GeminiCliProvider } from "./runners/gemini-cli.js";
import { GrokBuildCliProvider } from "./runners/grok-build-cli.js";

export class ProviderRegistry {
  private readonly providers = new Map<ProviderId, AiProvider>();

  register(provider: AiProvider): void {
    this.providers.set(provider.id, provider);
  }

  get(id: ProviderId): AiProvider | undefined {
    return this.providers.get(id);
  }

  list(): AiProvider[] {
    return [...this.providers.values()];
  }
}

export interface OfficialProviderOptions {
  spawn?: CliSpawn;
  modelConfig?: Partial<Record<ProviderId, ModelConfig>>;
  executables?: Partial<Record<"codex" | "claude" | "gemini" | "grok", string>>;
  api?: { subscriptionOnly?: boolean; apiKey?: string };
}

/** Opt-in registry. Importing this module does not start a CLI or change workers. */
export function createOfficialProviderRegistry(
  options: OfficialProviderOptions = {},
): ProviderRegistry {
  const spawn = options.spawn ?? defaultCliSpawn;
  const registry = new ProviderRegistry();
  registry.register(
    new CodexCliProvider({
      spawn,
      executable: options.executables?.codex,
      modelConfig: options.modelConfig?.codex,
    }),
  );
  registry.register(
    new ClaudeCodeCliProvider({
      spawn,
      executable: options.executables?.claude,
      modelConfig: options.modelConfig?.claude,
    }),
  );
  registry.register(
    new GeminiCliProvider({
      spawn,
      executable: options.executables?.gemini,
      modelConfig: options.modelConfig?.gemini,
    }),
  );
  registry.register(
    new GrokBuildCliProvider({
      spawn,
      executable: options.executables?.grok,
      modelConfig: options.modelConfig?.grok,
    }),
  );
  registry.register(
    new ApiProvider({
      subscriptionOnly: options.api?.subscriptionOnly,
      apiKey: options.api?.apiKey,
      modelConfig: options.modelConfig?.api,
    }),
  );
  return registry;
}
