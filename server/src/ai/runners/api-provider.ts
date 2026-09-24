import { resolveMaxContext, type ModelConfig } from "../model-policy.js";
import {
  providerFailure,
  type AiProvider,
  type ProviderCapabilities,
  type ProviderRunInput,
  type RawRunResult,
} from "../provider.js";

/**
 * Paid API mode is opt-in and still has no HTTP client.
 * subscriptionOnly refuses the run without reading process.env or auth files.
 * A CLI auth failure must never construct this provider as a fallback.
 */
export class ApiProvider implements AiProvider {
  readonly id = "api" as const;
  private readonly subscriptionOnly: boolean;
  private readonly apiKey: string | null;
  private readonly modelConfig: ModelConfig | null;
  private lastCallAt: string | null = null;

  constructor(options?: {
    subscriptionOnly?: boolean;
    apiKey?: string;
    modelConfig?: ModelConfig | null;
  }) {
    this.subscriptionOnly = options?.subscriptionOnly !== false;
    this.apiKey = options?.apiKey ?? null;
    this.modelConfig = options?.modelConfig ?? null;
  }

  probe(): Promise<ProviderCapabilities> {
    return Promise.resolve(this.capabilities());
  }

  run(_input: ProviderRunInput): Promise<RawRunResult> {
    this.lastCallAt = new Date().toISOString();
    if (this.subscriptionOnly) {
      return Promise.resolve(
        providerFailure(
          "AUTH_REQUIRED",
          "API provider is subscription-only and will not read an API key",
        ),
      );
    }
    if (!this.apiKey) {
      return Promise.resolve(
        providerFailure(
          "AUTH_REQUIRED",
          "API provider requires a key passed to the constructor",
        ),
      );
    }
    return Promise.resolve(
      providerFailure(
        "UNSUPPORTED_PLATFORM",
        "HTTP API client is not implemented",
      ),
    );
  }

  normalizeResult(): ReturnType<typeof providerFailure> {
    return providerFailure(
      "UNSUPPORTED_PLATFORM",
      "HTTP API client is not implemented",
    );
  }

  private capabilities(): ProviderCapabilities {
    return {
      providerId: "api",
      cliVersion: null,
      os: process.platform,
      arch: process.arch,
      loginMethod: this.subscriptionOnly ? "none" : "api_key",
      probedModels: [],
      structuredOutput: false,
      vision: false,
      maxContext: resolveMaxContext(this.modelConfig),
      health: "unavailable",
      lastCallAt: this.lastCallAt,
      mayBillExtra: !this.subscriptionOnly,
      platformSupported: false,
      quotaRemaining: "unknown",
    };
  }
}
