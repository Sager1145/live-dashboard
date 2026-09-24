import { randomUUID } from "node:crypto";

export const identityKinds = [
  "event",
  "edition",
  "stop",
  "performance",
  "goodsSession",
] as const;

export type IdentityKind = (typeof identityKinds)[number];

export type IdentityDescriptor = {
  title: string | null;
  localDate: string | null;
  venue: string | null;
};

export type IdentityRemap = {
  fromId: string;
  toId: string;
  reason: string;
};

/** Fields a model may emit. Only `externalKey` can select an existing id. */
export type IdentityHint = {
  externalKey?: string | null;
  title?: string | null;
  localDate?: string | null;
  venue?: string | null;
  index?: number | null;
  modelId?: string | null;
};

const kindSet = new Set<string>(identityKinds);

function emptyDescriptor(): IdentityDescriptor {
  return { title: null, localDate: null, venue: null };
}

/**
 * In-memory stable ids. `allocate` is the only mint.
 * External keys stay bound to that id; title, date, index, and modelId are not keys.
 */
export class IdentityRegistry {
  private readonly records = new Map<
    string,
    { kind: IdentityKind; descriptor: IdentityDescriptor }
  >();
  private readonly aliases = new Map<string, string>();
  private readonly remapLog: IdentityRemap[] = [];

  allocate(kind: IdentityKind): string {
    if (!kindSet.has(kind)) throw new Error(`unknown identity kind: ${kind}`);
    const id = `${kind}_${randomUUID()}`;
    this.records.set(id, { kind, descriptor: emptyDescriptor() });
    return id;
  }

  /** Official native id, canonical URL, or in-page anchor. Does not allocate. */
  lookup(externalKey: string): string | undefined {
    return this.aliases.get(externalKey);
  }

  /**
   * Same as `lookup`, but title, local date, venue, array index, and modelId are ignored.
   * Never mints an id.
   */
  lookupHint(hint: IdentityHint): string | undefined {
    if (typeof hint.externalKey !== "string" || hint.externalKey.length === 0)
      return undefined;
    return this.lookup(hint.externalKey);
  }

  remember(externalKey: string, id: string): void {
    if (externalKey.trim() === "") throw new Error("external key required");
    if (!this.records.has(id)) throw new Error("unknown id");
    const existing = this.aliases.get(externalKey);
    if (existing !== undefined && existing !== id)
      throw new Error(`external key already bound to ${existing}`);
    this.aliases.set(externalKey, id);
  }

  /**
   * Records a successor between existing ids.
   * Does not allocate, and does not retarget the external key (re-bind throws).
   */
  remap(fromId: string, toId: string, reason: string): void {
    if (!this.records.has(fromId) || !this.records.has(toId))
      throw new Error("unknown id");
    if (fromId === toId) throw new Error("remap requires distinct ids");
    if (reason.trim() === "") throw new Error("remap reason required");
    this.remapLog.push({ fromId, toId, reason });
  }

  updateDescriptor(
    id: string,
    partial: Partial<IdentityDescriptor>,
  ): IdentityDescriptor {
    const record = this.records.get(id);
    if (!record) throw new Error("unknown id");
    const next: IdentityDescriptor = { ...record.descriptor };
    if (partial.title !== undefined) next.title = partial.title;
    if (partial.localDate !== undefined) next.localDate = partial.localDate;
    if (partial.venue !== undefined) next.venue = partial.venue;
    record.descriptor = next;
    return { ...next };
  }

  descriptor(id: string): IdentityDescriptor | undefined {
    const record = this.records.get(id);
    return record ? { ...record.descriptor } : undefined;
  }

  kind(id: string): IdentityKind | undefined {
    return this.records.get(id)?.kind;
  }

  ids(): string[] {
    return [...this.records.keys()];
  }

  remaps(): IdentityRemap[] {
    return this.remapLog.map((entry) => ({ ...entry }));
  }
}
