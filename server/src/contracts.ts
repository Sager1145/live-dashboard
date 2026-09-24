import { z } from "zod";

const id = z.string().min(1).max(200);
const text = z.string().max(20000);
const instant = z.iso.datetime({ offset: true });
const nullableTime = instant.nullable().default(null);
const url = z
  .url()
  .refine((v) => new URL(v).protocol === "https:", "HTTPS URL required");
const nullableURL = url.nullable().default(null);
const optionalText = text.nullable().default(null);
export const officialLinkRoleSchema = z.enum([
  "application",
  "overseasApplication",
  "support",
  "product",
  "other",
]);
export const officialLinkSchema = z.object({
  label: z.string().min(1),
  url: z.url(),
  role: officialLinkRoleSchema.nullable().optional(),
  productNames: z.array(z.string().min(1)).optional(),
});
export const ticketNoteSchema = z.object({
  kind: z.enum([
    "faceRecognition",
    "companionRegistration",
    "identityCheck",
    "smartTicketOnly",
    "creditCardOnly",
    "membershipRequired",
    "other",
  ]),
  text: z.string().min(1),
  links: z.array(officialLinkSchema).default([]),
});
export const moneySchema = z.object({
  minorUnits: z.number().int().nonnegative().safe(),
  currency: z.string().regex(/^[A-Z]{3}$/),
});
export const scopeSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("performances"),
    performanceIDs: z.array(id).min(1),
  }),
  z.object({ kind: z.literal("unconfirmed") }),
]);
const status = z.enum([
  "confirmed",
  "officiallyTBA",
  "notFetched",
  "needsReview",
  "notApplicable",
]);
const base = { id, eventID: id };
const scoped = { ...base, scope: scopeSchema };
export const performanceSchema = z.object({
  ...base,
  editionID: id.nullable().optional(),
  stopID: id.nullable().default(null),
  dayLabel: text,
  subtitle: optionalText,
  localDate: z.iso.date().nullable(),
  precision: z
    .enum(["minute", "date", "month", "range", "unknown"])
    .default("date"),
  rawDate: optionalText,
  doorsAt: nullableTime,
  startAt: nullableTime,
  venueName: text,
  venueCity: text,
  performers: z.array(text),
  order: z.number().int(),
  timeZone: z.string().optional(),
});
export const evidenceSchema = z.object({
  id,
  recordID: id,
  field: text,
  sourceURL: url,
  quote: text.min(1),
  snapshotID: id,
  locator: text.min(1),
  sourcePublishedAt: nullableTime,
  observedAt: instant,
  verifiedAt: instant,
  verification: z.enum(["confirmed", "needsReview", "conflict"]),
  adapterVersion: text,
  performanceIDs: z.array(id).default([]),
});
export const bundleSchema = z.object({
  schemaVersion: z.literal(1),
  revision: z.number().int().nonnegative().default(0),
  publishedAt: instant,
  event: z
    .object({
      ...base,
      eventID: id.optional(),
      franchise: z.enum(["bangdream", "lovelive"]),
      officialTitle: text.min(1),
      groups: z.array(text),
      eventType: z.enum(["live", "fanMeeting", "screening", "other"]),
      status: z.enum(["scheduled", "postponed", "cancelled", "finished"]),
      primarySourceURL: url,
      timeZone: z.string().refine((v) => {
        try {
          new Intl.DateTimeFormat("en", { timeZone: v });
          return true;
        } catch {
          return false;
        }
      }, "Invalid IANA timezone"),
    })
    .omit({ eventID: true }),
  editions: z
    .array(z.object({ ...base, name: text, order: z.number().int() }))
    .default([]),
  stops: z
    .array(
      z.object({
        ...base,
        name: text,
        order: z.number().int(),
        editionID: id.nullable().optional(),
        timeZone: z.string().optional(),
      }),
    )
    .default([]),
  performances: z.array(performanceSchema).min(1),
  ticketTiers: z
    .array(
      z.object({
        ...base,
        name: text,
        priceJPY: z.number().int().nonnegative().nullable().default(null),
        amount: moneySchema.nullable().optional(),
        priceKind: z.enum([
          "full",
          "upgradeDifference",
          "streaming",
          "under20",
        ]),
        includes: optionalText,
        feeNote: optionalText,
        taxNote: optionalText,
      }),
    )
    .default([]),
  ticketRounds: z
    .array(
      z.object({
        ...scoped,
        officialName: text,
        kind: z.enum([
          "lottery",
          "firstComeFirstServed",
          "resale",
          "upgrade",
          "other",
        ]),
        applyStartAt: nullableTime,
        applyEndAt: nullableTime,
        resultAt: nullableTime,
        paymentDeadlineAt: nullableTime,
        eligibility: optionalText,
        announcementURL: nullableURL,
        applyURL: nullableURL,
        overseasURL: nullableURL,
        officialStatus: optionalText,
        status,
        links: z.array(officialLinkSchema).default([]),
        applyWindowText: optionalText,
        resultText: optionalText,
        paymentStartAt: nullableTime,
        paymentWindowText: optionalText,
        quantityLimit: optionalText,
        lotteryProducts: z.array(z.string()).default([]),
        applicationTarget: optionalText,
        notes: z.array(ticketNoteSchema).default([]),
      }),
    )
    .default([]),
  ticketBenefits: z
    .array(
      z.object({
        ...scoped,
        officialName: text,
        tierIDs: z.array(id).default([]),
        detail: optionalText,
        notes: optionalText,
        redemptionLocation: optionalText,
        redemptionWindow: optionalText,
        redemptionNote: optionalText,
        mediaAssetIDs: z.array(id).default([]),
        status,
        links: z.array(officialLinkSchema).default([]),
      }),
    )
    .default([]),
  ticketOffers: z
    .array(
      z.object({
        id,
        roundID: id,
        tierID: id,
        performanceIDs: z.array(id).min(1),
        priceJPY: z.number().int().nonnegative().nullable().default(null),
        amount: moneySchema.nullable().optional(),
      }),
    )
    .default([]),
  streamOffers: z
    .array(
      z.object({
        ...scoped,
        platform: text,
        officialName: text,
        salesEndAt: nullableTime,
        salesStartAt: nullableTime,
        archiveAvailableUntil: nullableTime,
        regionNote: optionalText,
        url: nullableURL,
        amount: moneySchema.nullable().optional(),
        status,
      }),
    )
    .default([]),
  goodsCampaigns: z
    .array(
      z.object({
        ...scoped,
        officialName: text,
        channel: z.enum(["online", "venue"]),
        fulfillment: z.enum(["shipping", "venuePickup"]),
        phase: z.enum(["pre", "during", "post"]),
        salesStartAt: nullableTime,
        salesEndAt: nullableTime,
        pickupWindow: optionalText,
        shippingNote: optionalText,
        location: optionalText,
        requiresTicket: z.boolean().nullable().default(null),
        purchaseLimit: optionalText,
        paymentMethods: optionalText,
        url: nullableURL,
        mediaAssetIDs: z.array(id),
        status,
        links: z.array(officialLinkSchema).default([]),
      }),
    )
    .default([]),
  products: z
    .array(
      z.object({
        ...base,
        campaignID: id,
        name: text,
        amount: moneySchema.nullable().optional(),
        url: nullableURL,
        variants: z
          .array(
            z.object({
              id,
              name: text,
              amount: moneySchema.nullable().optional(),
              stockStatus: optionalText,
            }),
          )
          .default([]),
        purchaseLimit: optionalText,
      }),
    )
    .default([]),
  goodsSessions: z
    .array(
      z.object({
        ...scoped,
        campaignID: id,
        startsAt: nullableTime,
        endsAt: nullableTime,
        location: text,
      }),
    )
    .default([]),
  mediaAssets: z
    .array(
      z.object({
        ...scoped,
        kind: z.enum([
          "keyVisual",
          "goodsList",
          "product",
          "venueGoodsNotice",
          "goodsAreaMap",
          "eventSeatingMap",
          "venueGenericSeatingMap",
          "standingArea",
        ]),
        originalURL: url,
        thumbnailURL: nullableURL,
        sourceURL: url,
        version: z.number().int().positive(),
        caption: optionalText,
        displayPolicy: z
          .enum(["link_only", "permitted_remote_display", "permitted_cache"])
          .default("link_only"),
        contentHash: z
          .string()
          .regex(/^[a-f0-9]{64}$/)
          .optional(),
      }),
    )
    .default([]),
  notices: z
    .array(
      z.object({
        ...scoped,
        kind: z.enum([
          "change",
          "cancellation",
          "postponement",
          "refund",
          "other",
        ]),
        title: text,
        body: text,
        publishedAt: nullableTime,
        sourceURL: url,
      }),
    )
    .default([]),
  evidence: z.array(evidenceSchema),
  sourceHealth: z
    .enum(["healthy", "stale", "fetch_failed", "blocked", "parse_failed"])
    .default("healthy"),
  sourceText: z.string().max(80000).nullable().optional(),
});
export type Bundle = z.infer<typeof bundleSchema>;
export type Scope = z.infer<typeof scopeSchema>;
export class DomainError extends Error {
  constructor(
    public statusCode: number,
    message: string,
  ) {
    super(message);
  }
}
export function parseBundle(input: unknown): Bundle {
  const b = bundleSchema.parse(input);
  const all = [
    b.event,
    ...b.editions,
    ...b.stops,
    ...b.performances,
    ...b.ticketTiers,
    ...b.ticketRounds,
    ...b.ticketOffers,
    ...b.streamOffers,
    ...b.goodsCampaigns,
    ...b.products,
    ...b.products.flatMap((p) => p.variants),
    ...b.goodsSessions,
    ...b.mediaAssets,
    ...b.notices,
  ];
  const ids = new Set<string>();
  for (const r of all) {
    if (ids.has(r.id))
      throw new DomainError(422, `Duplicate entity ID ${r.id}`);
    ids.add(r.id);
    if ("eventID" in r && r.eventID !== b.event.id)
      throw new DomainError(422, "Cross-event record");
  }
  const performances = new Set(b.performances.map((p) => p.id));
  const checkMembers = (members: string[]) => {
    if (
      new Set(members).size !== members.length ||
      members.some((p) => !performances.has(p))
    )
      throw new DomainError(422, "Invalid performance membership");
  };
  for (const r of all)
    if ("scope" in r && r.scope.kind === "performances")
      checkMembers(r.scope.performanceIDs);
  for (const s of b.stops)
    if (s.editionID && !b.editions.some((e) => e.id === s.editionID))
      throw new DomainError(422, "Unknown stop edition");
  for (const p of b.performances) {
    if (p.stopID && !b.stops.some((s) => s.id === p.stopID))
      throw new DomainError(422, "Unknown stop");
    if (p.editionID && !b.editions.some((e) => e.id === p.editionID))
      throw new DomainError(422, "Unknown edition");
    if (p.doorsAt && p.startAt && Date.parse(p.doorsAt) > Date.parse(p.startAt))
      throw new DomainError(422, "Doors after start");
  }
  for (const o of b.ticketOffers) {
    checkMembers(o.performanceIDs);
    const round = b.ticketRounds.find((r) => r.id === o.roundID);
    if (!round || !b.ticketTiers.some((t) => t.id === o.tierID))
      throw new DomainError(422, "Unknown ticket relationship");
    const scope = round.scope;
    if (
      scope.kind !== "performances" ||
      o.performanceIDs.some((p) => !scope.performanceIDs.includes(p))
    )
      throw new DomainError(422, "Offer exceeds round scope");
  }
  for (const r of b.ticketRounds)
    if (
      r.applyStartAt &&
      r.applyEndAt &&
      Date.parse(r.applyStartAt) > Date.parse(r.applyEndAt)
    )
      throw new DomainError(422, "Reversed application interval");
  for (const p of [...b.products, ...b.goodsSessions])
    if (!b.goodsCampaigns.some((c) => c.id === p.campaignID))
      throw new DomainError(422, "Unknown goods campaign");
  for (const c of b.goodsCampaigns)
    if (c.mediaAssetIDs.some((id) => !b.mediaAssets.some((m) => m.id === id)))
      throw new DomainError(422, "Unknown campaign media");
  for (const e of b.evidence) {
    if (!ids.has(e.recordID))
      throw new DomainError(422, "Evidence references unknown entity");
    checkMembers(e.performanceIDs);
  }
  return b;
}
export function assertEvidence(b: Bundle) {
  const required: [string, string][] = [[b.event.id, "officialTitle"]];
  for (const p of b.performances) {
    if (p.localDate) required.push([p.id, "localDate"]);
    for (const f of ["doorsAt", "startAt", "venueName"] as const)
      if (p[f]) required.push([p.id, f]);
  }
  for (const t of b.ticketTiers)
    if (t.amount || t.priceJPY !== null)
      required.push([t.id, t.amount ? "amount" : "priceJPY"]);
  for (const r of b.ticketRounds)
    for (const f of [
      "applyStartAt",
      "applyEndAt",
      "resultAt",
      "paymentDeadlineAt",
      "eligibility",
    ] as const)
      if (r[f]) required.push([r.id, f]);
  for (const c of b.goodsCampaigns)
    for (const f of [
      "salesStartAt",
      "salesEndAt",
      "requiresTicket",
      "purchaseLimit",
    ] as const)
      if (c[f] !== null) required.push([c.id, f]);
  for (const s of b.streamOffers)
    for (const f of [
      "salesStartAt",
      "salesEndAt",
      "archiveAvailableUntil",
      "regionNote",
      "amount",
    ] as const)
      if (s[f]) required.push([s.id, f]);
  for (const p of b.products) {
    if (p.amount) required.push([p.id, "amount"]);
    for (const v of p.variants) if (v.amount) required.push([v.id, "amount"]);
  }
  for (const o of b.ticketOffers) {
    required.push([o.id, "performanceIDs"]);
    if (o.amount || o.priceJPY !== null)
      required.push([o.id, o.amount ? "amount" : "priceJPY"]);
  }
  for (const s of b.goodsSessions)
    for (const f of ["startsAt", "endsAt"] as const)
      if (s[f]) required.push([s.id, f]);
  for (const m of b.mediaAssets) required.push([m.id, "kind"], [m.id, "scope"]);
  for (const r of [
    ...b.ticketRounds,
    ...b.goodsCampaigns,
    ...b.streamOffers,
    ...b.goodsSessions,
  ])
    if (r.scope.kind === "performances") required.push([r.id, "scope"]);
  for (const [record, field] of required)
    if (
      !b.evidence.some(
        (e) =>
          e.recordID === record &&
          e.field === field &&
          e.verification === "confirmed",
      )
    )
      throw new DomainError(
        422,
        `Missing confirmed evidence: ${record}.${field}`,
      );
}
export function matchesScope(scope: Scope, performanceID: string) {
  return (
    scope.kind === "performances" &&
    scope.performanceIDs.includes(performanceID)
  );
}

const sha256Schema = z.string().regex(/^[a-f0-9]{64}$/);
const decimalCursorSchema = z.string().regex(/^(0|[1-9][0-9]*)$/);
const localClockSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);
export const fieldAbsenceSchema = z.enum([
  "notAnnounced",
  "unresolved",
  "unavailable",
  "conflict",
  "notApplicable",
]);
export const applicabilityCodeSchema = z.enum([
  "headingUnparsed",
  "parentScopeChanged",
  "mixedPerformances",
  "rangeNotInSource",
  "sourceConflict",
]);
const fieldAbsenceEntrySchema = z.object({
  recordID: id,
  field: z.string().min(1).max(80),
  absence: fieldAbsenceSchema,
});
const applicabilityEntrySchema = z.object({
  recordID: id,
  code: applicabilityCodeSchema,
  detail: text.min(1),
});
const aliasSchema = z.object({ legacyID: id, currentID: id });
export const legacyAliasesSchema = z.object({
  events: z.array(aliasSchema).default([]),
  performances: z.array(aliasSchema).default([]),
  tickets: z.array(aliasSchema).default([]),
  goods: z.array(aliasSchema).default([]),
});
const mediaVariantSchema = z.object({
  contentHash: sha256Schema,
  path: z.string().min(1),
  contentType: z.string().min(1),
  width: z.number().int().positive(),
  height: z.number().int().positive(),
  byteSize: z.number().int().nonnegative(),
});
const mediaManifestAssetSchema = z.object({
  assetID: id,
  logicalImageID: id,
  role: z.enum([
    "keyVisual",
    "goodsList",
    "product",
    "venueGoodsNotice",
    "goodsAreaMap",
    "eventSeatingMap",
    "venueGenericSeatingMap",
    "standingArea",
  ]),
  order: z.number().int().nonnegative(),
  scope: scopeSchema,
  displayPolicy: z.enum([
    "link_only",
    "permitted_remote_display",
    "permitted_cache",
  ]),
  state: z.enum(["ready", "pending", "withdrawn"]),
  variants: z.object({
    original: mediaVariantSchema.optional(),
    preview: mediaVariantSchema.optional(),
  }),
  sourceReferenceID: id,
});
export const mediaManifestSchema = z.object({
  eventID: id,
  revision: z.number().int().nonnegative(),
  assets: z.array(mediaManifestAssetSchema),
});
export const performanceSchemaV2 = performanceSchema.extend({
  localTime: localClockSchema.nullable().default(null),
});
export const evidenceSchemaV2 = evidenceSchema.extend({
  blockID: id.optional(),
  assetID: id.optional(),
  contentHash: sha256Schema.optional(),
});
export const bundleSchemaV2 = bundleSchema
  .omit({ schemaVersion: true, performances: true, evidence: true })
  .extend({
    schemaVersion: z.literal(2),
    sourceCheckedAt: instant,
    performances: z.array(performanceSchemaV2).min(1),
    evidence: z.array(evidenceSchemaV2),
    fieldAbsences: z.array(fieldAbsenceEntrySchema).default([]),
    applicability: z.array(applicabilityEntrySchema).default([]),
    mediaManifest: mediaManifestSchema,
    legacyAliases: legacyAliasesSchema.default({
      events: [],
      performances: [],
      tickets: [],
      goods: [],
    }),
  });
export type BundleV2 = z.infer<typeof bundleSchemaV2>;

export function compareDecimalCursor(a: string, b: string) {
  decimalCursorSchema.parse(a);
  decimalCursorSchema.parse(b);
  if (a.length !== b.length) return a.length < b.length ? -1 : 1;
  return a < b ? -1 : a > b ? 1 : 0;
}

/**
 * Returns an instant only when one was already known.
 * A date or clock without that instant stays unknown: this does not invent UTC midnight.
 */
export function performanceStartInstant(input: {
  localDate: string | null;
  localTime: string | null;
  knownInstant: string | null;
}) {
  if (input.knownInstant !== null) return input.knownInstant;
  if (input.localDate !== null && input.localTime === null) return null;
  return null;
}

export function acceptEventRevision(current: number | null, next: number) {
  if (!Number.isInteger(next) || next < 0)
    throw new DomainError(422, "Invalid event revision");
  if (current !== null && next < current)
    throw new DomainError(409, "Event revision regressed");
}

export function mergeProposedField<T>(
  verified: T | null,
  proposed: T | null,
  clear: { verified: boolean },
): T | null {
  if (proposed !== null) return proposed;
  if (clear.verified) return null;
  return verified;
}

export function canCommitCursor(
  savedEventIDs: ReadonlySet<string>,
  windowEventIDs: readonly string[],
) {
  return windowEventIDs.every((eventID) => savedEventIDs.has(eventID));
}

function entityIDs(b: BundleV2) {
  const ids = new Set<string>([b.event.id]);
  for (const group of [
    b.editions,
    b.stops,
    b.performances,
    b.ticketTiers,
    b.ticketRounds,
    b.ticketBenefits,
    b.ticketOffers,
    b.streamOffers,
    b.goodsCampaigns,
    b.products,
    b.products.flatMap((product) => product.variants),
    b.goodsSessions,
    b.mediaAssets,
    b.notices,
  ])
    for (const record of group) ids.add(record.id);
  return ids;
}

function scopedByID(b: BundleV2) {
  const records = [
    ...b.ticketRounds,
    ...b.ticketBenefits,
    ...b.streamOffers,
    ...b.goodsCampaigns,
    ...b.goodsSessions,
    ...b.mediaAssets,
    ...b.notices,
  ];
  return new Map(records.map((record) => [record.id, record.scope]));
}

function requireUniqueLegacy(aliases: { legacyID: string }[], kind: string) {
  const seen = new Set<string>();
  for (const alias of aliases) {
    if (seen.has(alias.legacyID))
      throw new DomainError(
        422,
        `Duplicate ${kind} legacy ID ${alias.legacyID}`,
      );
    seen.add(alias.legacyID);
  }
}

function variantPath(hash: string, variant: "original" | "preview") {
  return `/v2/assets/${hash}/${variant}`;
}

function validatePublishedManifest(b: BundleV2) {
  const manifest = b.mediaManifest;
  if (manifest.eventID !== b.event.id || manifest.revision !== b.revision)
    throw new DomainError(422, "Media manifest identity mismatch");
  const assets = new Map(b.mediaAssets.map((asset) => [asset.id, asset]));
  const seen = new Set<string>();
  for (const entry of manifest.assets) {
    if (seen.has(entry.logicalImageID))
      throw new DomainError(
        422,
        `Duplicate manifest image ${entry.logicalImageID}`,
      );
    seen.add(entry.logicalImageID);
    const asset = assets.get(entry.logicalImageID);
    if (!asset)
      throw new DomainError(422, "Manifest image is not in the bundle");
    if (
      entry.role !== asset.kind ||
      entry.displayPolicy !== asset.displayPolicy ||
      JSON.stringify(entry.scope) !== JSON.stringify(asset.scope)
    )
      throw new DomainError(422, "Manifest diverges from media asset");
    if (entry.state === "pending")
      throw new DomainError(422, "Unpublished media cannot ship in a bundle");
    const downloadable =
      entry.displayPolicy === "permitted_cache" ||
      entry.displayPolicy === "permitted_remote_display";
    if (downloadable && !entry.variants.original)
      throw new DomainError(
        422,
        "Downloadable media is missing original bytes",
      );
    for (const name of ["original", "preview"] as const) {
      const variant = entry.variants[name];
      if (variant && variant.path !== variantPath(variant.contentHash, name))
        throw new DomainError(422, "Asset path does not match its hash");
    }
  }
  if (seen.size !== assets.size)
    throw new DomainError(422, "Media manifest omitted a bundle image");
}

export function parseBundleV2(input: unknown): BundleV2 {
  const parsed = bundleSchemaV2.parse(input);
  parseBundle({ ...parsed, schemaVersion: 1 });
  const ids = entityIDs(parsed);
  const scopes = scopedByID(parsed);
  for (const entry of parsed.fieldAbsences)
    if (!ids.has(entry.recordID))
      throw new DomainError(422, "Field absence cites an unknown record");
  for (const entry of parsed.applicability) {
    const scope = scopes.get(entry.recordID);
    if (!scope)
      throw new DomainError(422, "Applicability cites an unknown record");
    if (scope.kind !== "unconfirmed")
      throw new DomainError(
        422,
        "Applicability diagnostic is only for an unconfirmed scope",
      );
  }
  const aliases = parsed.legacyAliases;
  requireUniqueLegacy(aliases.events, "event");
  requireUniqueLegacy(aliases.performances, "performance");
  requireUniqueLegacy(aliases.tickets, "ticket");
  requireUniqueLegacy(aliases.goods, "goods");
  const ticketIDs = new Set([
    ...parsed.ticketTiers.map((tier) => tier.id),
    ...parsed.ticketRounds.map((round) => round.id),
    ...parsed.ticketOffers.map((offer) => offer.id),
    ...parsed.ticketBenefits.map((benefit) => benefit.id),
  ]);
  const goodsIDs = new Set([
    ...parsed.goodsCampaigns.map((campaign) => campaign.id),
    ...parsed.products.map((product) => product.id),
    ...parsed.products.flatMap((product) =>
      product.variants.map((variant) => variant.id),
    ),
    ...parsed.goodsSessions.map((session) => session.id),
  ]);
  for (const alias of aliases.events)
    if (alias.currentID !== parsed.event.id)
      throw new DomainError(422, "Event alias leaves this bundle");
  for (const alias of aliases.performances)
    if (
      !parsed.performances.some(
        (performance) => performance.id === alias.currentID,
      )
    )
      throw new DomainError(422, "Performance alias leaves this bundle");
  for (const alias of aliases.tickets)
    if (!ticketIDs.has(alias.currentID))
      throw new DomainError(422, "Ticket alias leaves this bundle");
  for (const alias of aliases.goods)
    if (!goodsIDs.has(alias.currentID))
      throw new DomainError(422, "Goods alias leaves this bundle");
  validatePublishedManifest(parsed);
  return parsed;
}

const changeBase = {
  sequence: decimalCursorSchema,
  eventID: id,
};
export const catalogChangesSchema = z.object({
  schemaVersion: z.literal(2),
  serverInstanceID: id,
  fromCursor: decimalCursorSchema,
  cursor: decimalCursorSchema,
  watermark: decimalCursorSchema,
  hasMore: z.boolean(),
  nextPageToken: z.string().min(1).nullable(),
  changes: z.array(
    z.discriminatedUnion("kind", [
      z.object({
        ...changeBase,
        kind: z.literal("upsert"),
        revision: z.number().int().nonnegative(),
        bundle: bundleSchemaV2,
      }),
      z.object({
        ...changeBase,
        kind: z.literal("delete"),
        revision: z.number().int().nonnegative(),
      }),
      z.object({
        sequence: decimalCursorSchema,
        kind: z.literal("remap"),
        entityKind: z.enum(["event", "performance", "ticket", "goods"]),
        legacyID: id,
        currentID: id,
      }),
    ]),
  ),
  sourceHealth: z.record(
    z.string(),
    z.enum(["healthy", "stale", "fetch_failed", "blocked", "parse_failed"]),
  ),
});
export type CatalogChanges = z.infer<typeof catalogChangesSchema>;

export function parseCatalogChanges(input: unknown): CatalogChanges {
  const doc = catalogChangesSchema.parse(input);
  if (compareDecimalCursor(doc.cursor, doc.fromCursor) < 0)
    throw new DomainError(422, "Cursor precedes the window start");
  if (compareDecimalCursor(doc.cursor, doc.watermark) > 0)
    throw new DomainError(422, "Cursor passes the fixed watermark");
  if (doc.hasMore && doc.nextPageToken === null)
    throw new DomainError(422, "A continued window needs a page token");
  for (const change of doc.changes) {
    if (
      compareDecimalCursor(change.sequence, doc.fromCursor) <= 0 ||
      compareDecimalCursor(change.sequence, doc.cursor) > 0
    )
      throw new DomainError(422, "Change falls outside the fixed window");
    if (change.kind === "upsert") {
      if (
        change.bundle.event.id !== change.eventID ||
        change.bundle.revision !== change.revision
      )
        throw new DomainError(422, "Upsert bundle does not match the change");
    }
  }
  return doc;
}

export const catalogBootstrapSchema = z.object({
  schemaVersion: z.literal(2),
  serverInstanceID: id,
  snapshotID: id,
  cursor: decimalCursorSchema,
  watermark: decimalCursorSchema,
  hasMore: z.boolean(),
  nextPageToken: z.string().min(1).nullable(),
  events: z.array(bundleSchemaV2),
});
export const metaSchema = z
  .object({
    serverInstanceID: id,
    schemaVersions: z.array(z.union([z.literal(1), z.literal(2)])).min(1),
    capabilities: z.array(z.string().min(1).max(80)),
  })
  .strict();
export const identityMappingsSchema = z
  .object({
    serverInstanceID: id,
    mappings: z.array(
      z
        .object({
          entityKind: z.enum(["event", "performance", "ticket", "goods"]),
          legacyID: id,
          currentID: id,
        })
        .strict(),
    ),
  })
  .strict();
export const updateJobRequestSchema = z
  .object({
    target: z.discriminatedUnion("kind", [
      z.object({ kind: z.literal("catalog") }).strict(),
      z.object({ kind: z.literal("source"), sourceID: id }).strict(),
      z.object({ kind: z.literal("event"), eventID: id }).strict(),
      z
        .object({
          kind: z.literal("eventSection"),
          eventID: id,
          section: z.enum([
            "goods",
            "tickets",
            "performers",
            "schedule",
            "notices",
            "media",
            "stream",
          ]),
        })
        .strict(),
      z.object({ kind: z.literal("card"), eventID: id, cardID: id }).strict(),
      z.object({ kind: z.literal("history"), eventID: id }).strict(),
    ]),
    fetchLatest: z.boolean(),
    reextract: z.boolean(),
    reason: z.enum(["owner_requested", "schedule", "source_changed"]),
  })
  .strict();
export const updateJobAcceptedSchema = z.object({
  jobID: id,
  state: z.literal("queued"),
  deduplicated: z.boolean(),
  statusPath: z.string().regex(/^\/v2\/update-jobs\/[^/]+$/),
});
export const updateJobStatusSchema = z
  .object({
    jobID: id,
    state: z.enum([
      "queued",
      "running",
      "partial",
      "succeeded",
      "failed",
      "cancelled",
    ]),
    progress: z
      .object({
        sectionsCompleted: z.number().int().nonnegative(),
        sectionsTotal: z.number().int().nonnegative(),
        assetsReady: z.number().int().nonnegative(),
        assetsTotal: z.number().int().nonnegative(),
      })
      .strict(),
    published: z.array(
      z
        .object({
          eventID: id,
          revision: z.number().int().nonnegative(),
        })
        .strict(),
    ),
    issues: z.array(
      z
        .object({
          code: z.string().min(1).max(80),
          section: z.string().min(1).max(80).optional(),
        })
        .strict(),
    ),
  })
  .strict();
export const aiTaskSchema = z
  .object({
    taskID: id,
    taskType: z.enum([
      "goods",
      "tickets",
      "performers",
      "schedule",
      "notices",
      "media",
      "stream",
    ]),
    schemaVersion: z.literal(2),
    eventID: id,
    baseRevision: z.number().int().nonnegative(),
    snapshotID: id,
    blockIDs: z.array(id).min(1),
    scopeContext: z
      .object({
        allowedPerformanceIDs: z.array(id),
        parentHeading: text.nullable().default(null),
      })
      .strict(),
    allowedLinkIDs: z.array(id),
    allowedImageIDs: z.array(id),
    allowedFields: z.array(z.string().min(1).max(80)).min(1),
    inputText: z.string().max(80000),
  })
  .strict();
export const aiPatchResultSchema = z
  .object({
    taskID: id,
    patches: z.array(
      z
        .object({
          recordKind: z.enum([
            "goodsCampaign",
            "product",
            "ticketRound",
            "ticketTier",
            "performance",
            "notice",
            "mediaAsset",
            "streamOffer",
            "ticketBenefit",
          ]),
          recordRef: id,
          field: z.string().min(1).max(80),
          value: z.unknown(),
          evidenceRefs: z.array(id).min(1),
          state: z.literal("proposed"),
        })
        .strict(),
    ),
    unresolved: z.array(
      z
        .object({
          field: z.string().min(1).max(80),
          absence: fieldAbsenceSchema,
        })
        .strict(),
    ),
  })
  .strict();
export type AITask = z.infer<typeof aiTaskSchema>;
export type AIPatchResult = z.infer<typeof aiPatchResultSchema>;
export const aiTaskCacheKeySchema = z
  .object({
    provider: z.string().min(1),
    model: z.string().min(1),
    config: z.string().min(1),
    promptVersion: z.string().min(1),
    schemaVersion: z.literal(2),
    parserVersion: z.string().min(1),
    blockContentHashes: z.array(sha256Schema).min(1),
    parentScopeHash: sha256Schema,
    identityTableVersion: z.string().min(1),
    visualAssetHashes: z.array(sha256Schema),
  })
  .strict();
export const apnsCatalogInvalidationSchema = z
  .object({
    aps: z.object({ "content-available": z.literal(1) }).strict(),
    serverInstanceID: id,
    catalogWatermark: decimalCursorSchema,
  })
  .strict();

function collectURLs(value: unknown, found: string[]) {
  if (typeof value === "string") {
    if (/^https?:\/\//i.test(value)) found.push(value);
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) collectURLs(item, found);
    return;
  }
  if (value && typeof value === "object")
    for (const item of Object.values(value)) collectURLs(item, found);
}

function stringList(value: unknown) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string"))
    return null;
  return value as string[];
}

export function parseAIPatch(task: AITask, input: unknown): AIPatchResult {
  const result = aiPatchResultSchema.parse(input);
  if (result.taskID !== task.taskID)
    throw new DomainError(422, "Patch answers a different task");
  for (const patch of result.patches) {
    if (!task.allowedFields.includes(patch.field))
      throw new DomainError(422, `Field ${patch.field} is outside the task`);
    if (patch.field === "mediaAssetIDs") {
      const ids = stringList(patch.value);
      if (
        !ids ||
        ids.some((imageID) => !task.allowedImageIDs.includes(imageID))
      )
        throw new DomainError(422, "Image reference leaves the task");
    }
    if (patch.field === "links") {
      const ids = stringList(patch.value);
      if (!ids || ids.some((item) => !task.allowedLinkIDs.includes(item)))
        throw new DomainError(422, "Link reference leaves the task");
    }
    if (patch.field === "scope") {
      const scope = scopeSchema.safeParse(patch.value);
      if (!scope.success) throw new DomainError(422, "Invalid scope patch");
      if (
        scope.data.kind === "performances" &&
        scope.data.performanceIDs.some(
          (performanceID) =>
            !task.scopeContext.allowedPerformanceIDs.includes(performanceID),
        )
      )
        throw new DomainError(422, "Scope patch widens the task");
    }
    const urls: string[] = [];
    collectURLs(patch.value, urls);
    if (urls.some((found) => !task.inputText.includes(found)))
      throw new DomainError(422, "Patch URL is not in the source block");
  }
  return result;
}

export const v2JSONSchemas = {
  "live-event-bundle": bundleSchemaV2,
  "catalog-changes": catalogChangesSchema,
  "catalog-bootstrap": catalogBootstrapSchema,
  meta: metaSchema,
  "identity-mappings": identityMappingsSchema,
  "update-job-request": updateJobRequestSchema,
  "update-job-status": updateJobStatusSchema,
  "ai-task": aiTaskSchema,
  "ai-patch": aiPatchResultSchema,
  "ai-task-cache-key": aiTaskCacheKeySchema,
  "apns-catalog-invalidation": apnsCatalogInvalidationSchema,
} as const;
