import test from "node:test";
import assert from "node:assert/strict";
import {
  createValidationReceipt,
  validationReceiptFromProposedPatch,
  type ValidationReceipt,
} from "../src/validation-receipt.js";

function sample(actor: ValidationReceipt["actor"]): ValidationReceipt {
  return {
    policyVersion: "2026-09-24",
    snapshotHashes: [{ id: "snap", contentHash: "testhash" }],
    blockHashes: [{ id: "block", contentHash: "blockhash" }],
    taskHash: "task-1",
    outputHash: "output-1",
    fieldChecks: [
      { recordID: "event", field: "officialTitle", outcome: "pass" },
    ],
    scopeChecks: [
      { recordID: "round", kind: "performances", outcome: "pass" },
    ],
    readyAssetIDs: ["asset-1"],
    actor,
  };
}

test("validation receipt records policy, hashes, checks, ready assets, and actor", () => {
  const receipt = createValidationReceipt(sample("machine"));
  assert.equal(receipt.policyVersion, "2026-09-24");
  assert.deepEqual(receipt.snapshotHashes, [
    { id: "snap", contentHash: "testhash" },
  ]);
  assert.deepEqual(receipt.blockHashes, [
    { id: "block", contentHash: "blockhash" },
  ]);
  assert.equal(receipt.taskHash, "task-1");
  assert.equal(receipt.outputHash, "output-1");
  assert.equal(receipt.fieldChecks[0]?.outcome, "pass");
  assert.equal(receipt.scopeChecks[0]?.kind, "performances");
  assert.deepEqual(receipt.readyAssetIDs, ["asset-1"]);
  assert.equal(receipt.actor, "machine");
  assert.equal(createValidationReceipt(sample("human")).actor, "human");
  assert.notEqual(receipt.actor, "human");
});

test("a proposed model patch cannot create a validation receipt by itself", () => {
  const patch = {
    taskID: "task",
    patches: [
      {
        recordKind: "performance",
        recordRef: "p1",
        field: "localDate",
        value: null,
        evidenceRefs: ["e1"],
        state: "proposed" as const,
      },
    ],
    unresolved: [],
  };
  assert.throws(
    () => validationReceiptFromProposedPatch(patch),
    /proposed model patch cannot create a validation receipt/,
  );
  assert.throws(
    () => createValidationReceipt(patch),
    /proposed model patch cannot create a validation receipt/,
  );
  assert.throws(
    () =>
      createValidationReceipt({
        ...sample("machine"),
        patches: [{ state: "proposed" }],
      } as ValidationReceipt),
    /cannot create a validation receipt/,
  );
});

test("receipt actor is only machine or human", () => {
  assert.throws(
    () =>
      createValidationReceipt({
        ...sample("machine"),
        actor: "model" as "machine",
      }),
    /machine or human/,
  );
});
