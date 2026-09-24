import { z } from "zod";
import { SUBTASKS, type TaskEnvelope } from "./task-envelope.js";

export const FIELD_STATUSES = [
  "evidenced",
  "unpublished",
  "scope_unconfirmed",
  "source_unavailable",
  "conflicting",
  "not_applicable",
] as const;

export const ALLOWED_FIELDS: Record<
  (typeof SUBTASKS)[number],
  readonly string[]
> = {
  "identity-scope": ["identityCandidates", "performanceSet"],
  "schedule-performers": [
    "localDate",
    "openLocalTime",
    "startLocalTime",
    "venue",
    "performers",
    "appearanceScope",
  ],
  tickets: [
    "tiers",
    "rounds",
    "offers",
    "price",
    "saleWindow",
    "upgradeDifference",
    "limits",
    "benefits",
  ],
  goods: [
    "campaigns",
    "products",
    "sessions",
    "purchaseRules",
    "pickupRules",
    "imageIds",
  ],
  "seating-assets": [
    "assetRole",
    "performanceScope",
    "venueGeneric",
    "eventSpecific",
    "imageIds",
  ],
  "notices-streaming": [
    "streamOffers",
    "notices",
    "cancellationCandidate",
    "postponementCandidate",
  ],
};

const fieldSchema = z
  .object({
    name: z.string().min(1).max(120),
    status: z.enum(FIELD_STATUSES),
    value: z.unknown().optional(),
    evidenceLocatorIds: z.array(z.string()).default([]),
    imageIds: z.array(z.string()).default([]),
    linkIds: z.array(z.string()).default([]),
  })
  .strict();

/** Single schema for every provider after its own envelope is unwrapped. */
export const taskPatchSchema = z
  .object({
    subtask: z.enum(SUBTASKS),
    fields: z.array(fieldSchema),
  })
  .strict();

export type TaskPatch = z.infer<typeof taskPatchSchema>;

export const TASK_PATCH_JSON_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["subtask", "fields"],
  properties: {
    subtask: { type: "string", enum: [...SUBTASKS] },
    fields: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["name", "status"],
        properties: {
          name: { type: "string" },
          status: { type: "string", enum: [...FIELD_STATUSES] },
          value: {},
          evidenceLocatorIds: { type: "array", items: { type: "string" } },
          imageIds: { type: "array", items: { type: "string" } },
          linkIds: { type: "array", items: { type: "string" } },
        },
      },
    },
  },
} as const;

const URL_PATTERN = /\b(?:https?:\/\/|www\.)[^\s"'<>]+/i;

export type ValidationResult =
  | {
      ok: true;
      value: TaskPatch;
      repaired: boolean;
      quotaRemaining: "unknown";
    }
  | {
      ok: false;
      code: "INVALID_OUTPUT";
      message: string;
      quotaRemaining: "unknown";
      retryAfterMs: null;
      review?: "fact_conflict";
    };

function invalid(message: string, review?: "fact_conflict"): ValidationResult {
  return {
    ok: false,
    code: "INVALID_OUTPUT",
    message,
    quotaRemaining: "unknown",
    retryAfterMs: null,
    ...(review ? { review } : {}),
  };
}

function collectStrings(value: unknown, out: string[]): void {
  if (typeof value === "string") {
    out.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, out);
    return;
  }
  if (value && typeof value === "object") {
    for (const child of Object.values(value)) collectStrings(child, out);
  }
}

function collectKeyedIds(
  value: unknown,
  keys: Set<string>,
  out: string[],
): void {
  if (Array.isArray(value)) {
    for (const item of value) collectKeyedIds(item, keys, out);
    return;
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (keys.has(key)) {
      if (typeof child === "string") out.push(child);
      else if (Array.isArray(child)) {
        for (const item of child) if (typeof item === "string") out.push(item);
      }
    }
    collectKeyedIds(child, keys, out);
  }
}

type Structural =
  | { ok: true; value: TaskPatch }
  | { ok: false; message: string };

function parseStructurally(text: string, envelope: TaskEnvelope): Structural {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, message: "Model output is not JSON" };
  }
  const result = taskPatchSchema.safeParse(parsed);
  if (!result.success) {
    return {
      ok: false,
      message:
        result.error.issues[0]?.message ??
        "Model output failed schema validation",
    };
  }
  if (result.data.subtask !== envelope.subtask) {
    return { ok: false, message: "Model subtask does not match the envelope" };
  }
  const allowed = new Set(ALLOWED_FIELDS[envelope.fieldSchemaName]);
  for (const field of result.data.fields) {
    if (!allowed.has(field.name)) {
      return {
        ok: false,
        message: `Field ${field.name} is not in the allowed set`,
      };
    }
  }
  return { ok: true, value: result.data };
}

function semanticFailure(
  value: TaskPatch,
  envelope: TaskEnvelope,
): ValidationResult | null {
  const strings: string[] = [];
  collectStrings(value, strings);
  if (strings.some((item) => URL_PATTERN.test(item))) {
    return invalid(
      "Model output contains a URL that was not supplied as an id",
    );
  }
  const imageIds: string[] = [];
  collectKeyedIds(
    value,
    new Set(["imageId", "imageID", "imageIds", "imageIDs"]),
    imageIds,
  );
  const allowedImages = new Set(envelope.allowedImageIds);
  for (const imageId of imageIds) {
    if (!allowedImages.has(imageId)) {
      return invalid(`Image id ${imageId} was not in the supplied image ids`);
    }
  }
  const linkIds: string[] = [];
  collectKeyedIds(
    value,
    new Set(["linkId", "linkID", "linkIds", "linkIDs"]),
    linkIds,
  );
  const allowedLinks = new Set(envelope.allowedLinkIds);
  for (const linkId of linkIds) {
    if (!allowedLinks.has(linkId)) {
      return invalid(`Link id ${linkId} was not in the supplied link ids`);
    }
  }
  if (value.fields.some((field) => field.status === "conflicting")) {
    return invalid(
      "Fact conflict requires review and was not repaired",
      "fact_conflict",
    );
  }
  const confirmed = new Map(
    envelope.confirmedIdentity.map((row) => [row.field, row.value]),
  );
  for (const field of value.fields) {
    const expected = confirmed.get(field.name);
    if (
      expected !== undefined &&
      field.status === "evidenced" &&
      typeof field.value === "string" &&
      field.value !== expected
    ) {
      return invalid(
        `Fact conflict on ${field.name}; not auto-repaired`,
        "fact_conflict",
      );
    }
  }
  return null;
}

export async function validateModelOutput(options: {
  text: string;
  envelope: TaskEnvelope;
  repair?: (text: string) => string | Promise<string>;
}): Promise<ValidationResult> {
  const first = parseStructurally(options.text, options.envelope);
  if (first.ok) {
    return (
      semanticFailure(first.value, options.envelope) ?? {
        ok: true,
        value: first.value,
        repaired: false,
        quotaRemaining: "unknown",
      }
    );
  }
  if (!options.repair) return invalid(first.message);
  let repairedText: string;
  try {
    repairedText = await options.repair(options.text);
  } catch {
    return invalid("Structural repair failed");
  }
  const second = parseStructurally(repairedText, options.envelope);
  if (!second.ok) return invalid(second.message);
  const semantic = semanticFailure(second.value, options.envelope);
  if (semantic) return semantic;
  return {
    ok: true,
    value: second.value,
    repaired: true,
    quotaRemaining: "unknown",
  };
}
