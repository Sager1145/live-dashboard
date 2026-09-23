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
  performances: z
    .array(
      z.object({
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
      }),
    )
    .min(1),
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
  evidence: z.array(
    z.object({
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
    }),
  ),
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
