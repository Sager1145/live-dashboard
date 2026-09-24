export interface ModelConfig {
  /** Empty or omitted means the CLI's own default. Never a baked-in model id. */
  model?: string | null;
  maxContext?: number | null;
}

export function resolveModelName(
  config: ModelConfig | null | undefined,
): string | null {
  if (!config || config.model == null) return null;
  const trimmed = config.model.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export function resolveMaxContext(
  config: ModelConfig | null | undefined,
): number | null {
  if (!config || config.maxContext == null) return null;
  if (!Number.isFinite(config.maxContext) || config.maxContext <= 0)
    return null;
  return config.maxContext;
}
