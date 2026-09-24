import { DomainError } from "./contracts.js";

export const VALIDATION_POLICY_VERSION = "2026-09-24";

export type ValidationActor = "machine" | "human";

export type FieldCheckOutcome = "pass" | "conflict" | "missing" | "needsReview";

export type FieldCheck = {
  recordID: string;
  field: string;
  outcome: FieldCheckOutcome;
};

export type ScopeCheck = {
  recordID: string;
  kind: "performances" | "unconfirmed";
  outcome: "pass" | "needsReview";
};

export type ContentHashRef = { id: string; contentHash: string };

/**
 * Validator output. A model patch whose state is only "proposed" is not a receipt.
 * Machine and human stay distinct actors; neither value means the other.
 */
export type ValidationReceipt = {
  policyVersion: string;
  snapshotHashes: ContentHashRef[];
  blockHashes: ContentHashRef[];
  taskHash: string;
  outputHash: string;
  fieldChecks: FieldCheck[];
  scopeChecks: ScopeCheck[];
  readyAssetIDs: string[];
  actor: ValidationActor;
};

type ProposedPatch = { patches?: { state?: string }[] };

function isProposedPatch(input: object): input is ProposedPatch {
  return "patches" in input && Array.isArray((input as ProposedPatch).patches);
}

/** A proposed model patch cannot mint a receipt, even if every other field is copied. */
export function validationReceiptFromProposedPatch(patch: ProposedPatch): never {
  const states = (patch.patches ?? []).map((item) => item.state);
  if (states.length === 0 || states.every((state) => state === "proposed"))
    throw new DomainError(
      422,
      "A proposed model patch cannot create a validation receipt",
    );
  throw new DomainError(
    422,
    "A model patch cannot create a validation receipt by itself",
  );
}

function requireHashList(
  value: unknown,
  label: string,
): ContentHashRef[] {
  if (!Array.isArray(value))
    throw new DomainError(422, `${label} must be a list`);
  return value.map((entry) => {
    if (
      !entry ||
      typeof entry !== "object" ||
      typeof (entry as ContentHashRef).id !== "string" ||
      !(entry as ContentHashRef).id ||
      typeof (entry as ContentHashRef).contentHash !== "string" ||
      !(entry as ContentHashRef).contentHash
    )
      throw new DomainError(422, `${label} entry is missing id or contentHash`);
    return {
      id: (entry as ContentHashRef).id,
      contentHash: (entry as ContentHashRef).contentHash,
    };
  });
}

export function createValidationReceipt(
  input: ValidationReceipt | ProposedPatch,
): ValidationReceipt {
  if (!input || typeof input !== "object")
    throw new DomainError(422, "Validation receipt required");
  if (isProposedPatch(input)) validationReceiptFromProposedPatch(input);
  const receipt = input as ValidationReceipt;
  if (typeof receipt.policyVersion !== "string" || !receipt.policyVersion.trim())
    throw new DomainError(422, "Validation policyVersion required");
  if (receipt.actor !== "machine" && receipt.actor !== "human")
    throw new DomainError(422, "Validation actor must be machine or human");
  if (typeof receipt.taskHash !== "string" || !receipt.taskHash)
    throw new DomainError(422, "Validation taskHash required");
  if (typeof receipt.outputHash !== "string" || !receipt.outputHash)
    throw new DomainError(422, "Validation outputHash required");
  if (!Array.isArray(receipt.fieldChecks) || !Array.isArray(receipt.scopeChecks))
    throw new DomainError(422, "Field and scope check summaries required");
  if (
    !Array.isArray(receipt.readyAssetIDs) ||
    receipt.readyAssetIDs.some((id) => typeof id !== "string" || !id)
  )
    throw new DomainError(422, "Ready asset ids must be a string list");
  for (const check of receipt.fieldChecks) {
    if (
      !check ||
      typeof check.recordID !== "string" ||
      typeof check.field !== "string" ||
      !["pass", "conflict", "missing", "needsReview"].includes(check.outcome)
    )
      throw new DomainError(422, "Invalid field check summary");
  }
  for (const check of receipt.scopeChecks) {
    if (
      !check ||
      typeof check.recordID !== "string" ||
      (check.kind !== "performances" && check.kind !== "unconfirmed") ||
      (check.outcome !== "pass" && check.outcome !== "needsReview")
    )
      throw new DomainError(422, "Invalid scope check summary");
  }
  return {
    policyVersion: receipt.policyVersion,
    snapshotHashes: requireHashList(receipt.snapshotHashes, "snapshotHashes"),
    blockHashes: requireHashList(receipt.blockHashes, "blockHashes"),
    taskHash: receipt.taskHash,
    outputHash: receipt.outputHash,
    fieldChecks: receipt.fieldChecks.map((check) => ({ ...check })),
    scopeChecks: receipt.scopeChecks.map((check) => ({ ...check })),
    readyAssetIDs: [...receipt.readyAssetIDs],
    actor: receipt.actor,
  };
}
