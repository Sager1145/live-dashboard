// Checks candidate facts extracted from one HTML block. A model may propose
// these. It may not invent a year, price, URL, or performance. Unknown is an
// empty value. This file does not call a model and is not part of the iOS app.

const amountPattern = /^-?\d+$/;

export function validateCandidates(candidates, blocks, knownPerformanceIDs = []) {
  const errors = [];
  for (const [index, candidate] of candidates.entries()) {
    const where = `candidates[${index}]`;
    if (!candidate.blockID) {
      errors.push(`${where} needs a blockID`);
      continue;
    }
    const block = blocks[candidate.blockID];
    if (block == null) {
      errors.push(`${where} block ${candidate.blockID} is not in the input`);
      continue;
    }
    if (candidate.value == null || candidate.value === "") continue;
    const evidence = String(candidate.evidence ?? "");
    if (!evidence || !block.includes(evidence)) {
      errors.push(`${where} evidence is not in block ${candidate.blockID}`);
    }
    if (candidate.kind === "amount" && !amountPattern.test(String(candidate.value))) {
      errors.push(`${where} amount must be an integer string`);
    }
    if (candidate.kind === "url") {
      try {
        const url = new URL(String(candidate.value));
        if (url.protocol !== "https:" && url.protocol !== "http:") errors.push(`${where} URL scheme`);
        if (!block.includes(String(candidate.value))) errors.push(`${where} URL is not in the block`);
      } catch {
        errors.push(`${where} URL is not parseable`);
      }
    }
    if (candidate.scope === "performances") {
      const ids = candidate.performanceIDs ?? [];
      if (!ids.length) errors.push(`${where} performance scope needs ids`);
      for (const id of ids) {
        if (!knownPerformanceIDs.includes(id)) errors.push(`${where} unknown performance ${id}`);
      }
    }
  }
  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const blocks = {
    ticket: "料金 9900円 受付期間：2026年9月1日 12:00～9月10日 23:59 https://eplus.jp/sample/",
  };
  const accepted = validateCandidates([
    { blockID: "ticket", kind: "amount", value: "9900", evidence: "9900円" },
    { blockID: "ticket", kind: "url", value: "https://eplus.jp/sample/", evidence: "https://eplus.jp/sample/" },
    { blockID: "ticket", kind: "text", value: null, evidence: "" },
  ], blocks, ["p1"]);
  const rejected = validateCandidates([
    { blockID: "missing", kind: "text", value: "x", evidence: "x" },
    { blockID: "ticket", kind: "url", value: "https://example.invalid/made-up", evidence: "made-up" },
    { blockID: "ticket", kind: "amount", value: "about 100", evidence: "about 100" },
    { blockID: "ticket", scope: "performances", performanceIDs: ["other"], value: "DAY2", evidence: "DAY2" },
  ], blocks, ["p1"]);
  if (accepted.length !== 0 || rejected.length < 4) {
    console.error({ accepted, rejected });
    process.exit(1);
  }
  console.log("validate-extraction-candidates self-test passed");
}
