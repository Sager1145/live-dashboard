import { randomUUID } from "node:crypto";
import { officialInstant } from "./local-time.js";
import type { DB } from "./db.js";
import { parseBundle, type Bundle, type Scope } from "./contracts.js";
import type {
  ParseResult,
  SourceSnapshot,
  FactCandidate,
} from "./ingestion/types.js";

/** Keeps parsed-but-unscoped records visible for editorial review, without turning them into actions. */
export async function mergeSnapshotDetails(
  db: DB,
  input: Bundle,
  parsed: ParseResult,
  snapshot: SourceSnapshot,
  explicitPerformanceID?: string,
): Promise<Bundle> {
  const b = structuredClone(input);
  const eventID = b.event.id;
  const now = new Date().toISOString();
  if (
    explicitPerformanceID &&
    !b.performances.some((p) => p.id === explicitPerformanceID)
  )
    throw new Error("Performance must belong to reviewed event");
  const identity = async (kind: string, key: string) => {
    const sourceKey = `${kind}:${snapshot.fetchUrl}#${key}`;
    await db.query(
      "INSERT INTO entity_aliases(source_key,entity_id,kind) VALUES($1,$2,$3) ON CONFLICT(source_key) DO NOTHING",
      [sourceKey, randomUUID(), kind],
    );
    return (
      await db.query(
        "SELECT entity_id FROM entity_aliases WHERE source_key=$1",
        [sourceKey],
      )
    ).rows[0].entity_id as string;
  };
  const scopeFor = (c: FactCandidate): Scope => {
    if (
      c.applicability.kind === "performances" &&
      c.applicability.performanceIds?.length
    )
      return {
        kind: "performances",
        performanceIDs: [...c.applicability.performanceIds],
      };
    const label = c.applicability.rawText;
    const matched = label
      ? b.performances.find((p) => p.dayLabel === label)
      : undefined;
    if (matched) return { kind: "performances", performanceIDs: [matched.id] };
    if (
      explicitPerformanceID &&
      !/3DAYS|multiple performances|unspecified/i.test(label ?? "")
    )
      return { kind: "performances", performanceIDs: [explicitPerformanceID] };
    return { kind: "unconfirmed" };
  };
  const evidence = (
    id: string,
    field: string,
    c: FactCandidate,
    scope?: Scope,
  ) => {
    b.evidence = b.evidence.filter(
      (e) => e.recordID !== id || e.field !== field,
    );
    b.evidence.push({
      id: randomUUID(),
      recordID: id,
      field,
      sourceURL: snapshot.finalUrl,
      quote: c.evidence.rawText,
      snapshotID: snapshot.id,
      locator: c.evidence.locator,
      sourcePublishedAt: null,
      observedAt: snapshot.fetchedAt,
      verifiedAt: now,
      verification: "needsReview",
      adapterVersion: c.parserVersion,
      performanceIDs:
        scope?.kind === "performances" ? scope.performanceIDs : [],
    });
  };
  const upsert = (key: keyof Bundle, value: any) => {
    const records = b[key] as any[];
    const index = records.findIndex((r) => r.id === value.id);
    if (index < 0) records.push(value);
    else records[index] = { ...records[index], ...value };
  };
  const campaignIDs = new Map<string, string>();
  for (const c of parsed.candidates) {
    const v = c.value as any;
    if (c.field === "goods.campaign" && v.sourceKey)
      campaignIDs.set(
        v.sourceKey,
        await identity("goodsCampaign", c.evidence.locator),
      );
  }
  for (const c of parsed.candidates) {
    const value = c.value as any;
    const key = c.evidence.locator;
    const scope = scopeFor(c);
    if (c.field === "performance.schedule" && value.localDate) {
      const matches = explicitPerformanceID
        ? b.performances.filter((p) => p.id === explicitPerformanceID)
        : b.performances.filter((p) => p.dayLabel === value.dayLabel);
      if (matches.length === 1) {
        const p = matches[0]!;
        const timeZone = value.timeZone ?? p.timeZone ?? b.event.timeZone;
        p.localDate = value.localDate;
        p.rawDate = value.raw ?? p.rawDate;
        p.timeZone = timeZone;
        p.precision = value.startsAt || value.doorsAt ? "minute" : "date";
        p.startAt = officialInstant(value.localDate, value.startsAt, timeZone);
        p.doorsAt = officialInstant(value.localDate, value.doorsAt, timeZone);
        evidence(p.id, "localDate", c, {
          kind: "performances",
          performanceIDs: [p.id],
        });
        for (const field of ["startAt", "doorsAt"] as const)
          if (p[field])
            evidence(p.id, field, c, {
              kind: "performances",
              performanceIDs: [p.id],
            });
      }
    }
    if (c.field === "ticket.tiers" && Array.isArray(value))
      for (const [index, t] of value.entries()) {
        if (!Number.isSafeInteger(t.amount) || t.amount < 0) continue;
        const id = await identity("ticketTier", `${key}:tier:${index}`);
        upsert("ticketTiers", {
          id,
          eventID,
          name: t.name,
          priceJPY: t.currency === "JPY" ? t.amount : null,
          amount: { minorUnits: t.amount, currency: t.currency ?? "JPY" },
          priceKind:
            t.priceKind === "upgrade_difference"
              ? "upgradeDifference"
              : t.priceKind === "under20"
                ? "under20"
                : "full",
          includes: null,
          feeNote: null,
          taxNote: null,
        });
        evidence(id, "amount", c);
      }
    if (
      (c.field === "ticket.round" || c.field === "ticket.resale") &&
      value.officialName
    ) {
      const id = await identity("ticketRound", key);
      const record = {
        id,
        eventID,
        officialName: value.officialName,
        kind:
          (
            {
              first_come: "firstComeFirstServed",
              first_come_first_served: "firstComeFirstServed",
            } as Record<string, string>
          )[value.kind] ??
          value.kind ??
          "other",
        scope,
        status: value.status ?? "needsReview",
        ...Object.fromEntries(
          [
            "applyStartAt",
            "applyEndAt",
            "resultAt",
            "paymentDeadlineAt",
            "eligibility",
            "applyURL",
            "announcementURL",
            "overseasURL",
            "officialStatus",
            "links",
            "applyWindowText",
            "resultText",
            "paymentStartAt",
            "paymentWindowText",
            "quantityLimit",
            "lotteryProducts",
            "applicationTarget",
            "notes",
          ]
            .filter((k) => value[k] !== undefined)
            .map((k) => [k, value[k]]),
        ),
      };
      upsert("ticketRounds", record);
      evidence(id, "scope", c, scope);
      for (const field of [
        "applyStartAt",
        "applyEndAt",
        "resultAt",
        "paymentDeadlineAt",
        "eligibility",
      ])
        if (value[field]) evidence(id, field, c, scope);
    }
    if (c.field === "stream.offer" && value.officialName) {
      const id = await identity("streamOffer", key);
      upsert("streamOffers", {
        id,
        eventID,
        scope,
        status: "needsReview",
        officialName: value.officialName,
        platform: value.platform ?? "",
        amount: value.amount ?? null,
        salesStartAt: value.salesStartAt ?? null,
        salesEndAt: value.salesEndAt ?? null,
        archiveAvailableUntil: value.archiveAvailableUntil ?? null,
        regionNote: value.regionNote ?? null,
        url: value.url ?? null,
      });
      evidence(id, "scope", c, scope);
      for (const field of [
        "amount",
        "salesStartAt",
        "salesEndAt",
        "archiveAvailableUntil",
        "regionNote",
      ])
        if (value[field]) evidence(id, field, c, scope);
    }
    if (c.field === "goods.campaign" && value.officialName) {
      const id = await identity("goodsCampaign", key);
      upsert("goodsCampaigns", {
        id,
        eventID,
        officialName: value.officialName,
        channel: value.channel ?? "online",
        fulfillment: value.fulfillment ?? "shipping",
        phase:
          (
            {
              pre_event: "pre",
              during_event: "during",
              post_event: "post",
            } as Record<string, string>
          )[value.phase] ??
          value.phase ??
          "pre",
        scope,
        status: "needsReview",
        mediaAssetIDs: [],
        ...Object.fromEntries(
          [
            "salesStartAt",
            "salesEndAt",
            "pickupWindow",
            "shippingNote",
            "location",
            "requiresTicket",
            "purchaseLimit",
            "paymentMethods",
            "url",
          ]
            .filter((k) => value[k] !== undefined)
            .map((k) => [k, value[k]]),
        ),
      });
      evidence(id, "scope", c, scope);
      for (const field of [
        "salesStartAt",
        "salesEndAt",
        "requiresTicket",
        "purchaseLimit",
      ])
        if (value[field] !== undefined && value[field] !== null)
          evidence(id, field, c, scope);
    }
  }
  for (const c of parsed.candidates) {
    const value = c.value as any;
    const campaignID = campaignIDs.get(value.campaignSourceKey);
    if (!campaignID) continue;
    const campaign = b.goodsCampaigns.find((r) => r.id === campaignID)!;
    if (c.field === "goods.product" && value.name) {
      const id = await identity(
        "product",
        `${campaignID}:${value.sourceProductKey ?? c.evidence.locator}`,
      );
      const variants: Bundle["products"][number]["variants"] = [];
      for (const v of value.variants ?? []) {
        const variantID = await identity(
          "productVariant",
          `${id}:${v.sourceVariantKey}`,
        );
        variants.push({
          id: variantID,
          name: v.name,
          amount: v.amount ?? null,
          stockStatus: v.stockStatus ?? null,
        });
        if (v.amount) evidence(variantID, "amount", c, campaign.scope);
      }
      const removedVariantIDs = new Set(
        (b.products.find((p) => p.id === id)?.variants ?? [])
          .map((v) => v.id)
          .filter((previous) => !variants.some((v) => v.id === previous)),
      );
      b.evidence = b.evidence.filter((e) => !removedVariantIDs.has(e.recordID));
      upsert("products", {
        id,
        eventID,
        campaignID,
        name: value.name,
        amount: value.amount ?? null,
        url: value.url ?? null,
        variants,
        purchaseLimit: value.purchaseLimit ?? null,
      });
      if (value.amount) evidence(id, "amount", c, campaign.scope);
    }
    if (c.field === "goods.session") {
      const id = await identity("goodsSession", c.evidence.locator);
      const scope = scopeFor(c);
      const startsAt = value.startsAt ?? value.salesStartAt ?? null;
      const endsAt = value.endsAt ?? value.salesEndAt ?? null;
      upsert("goodsSessions", {
        id,
        eventID,
        campaignID,
        scope,
        startsAt,
        endsAt,
        location: value.location ?? value.venueRaw ?? "",
      });
      evidence(id, "scope", c, scope);
      if (startsAt) evidence(id, "startsAt", c, scope);
      if (endsAt) evidence(id, "endsAt", c, scope);
    }
  }
  for (const media of parsed.media) {
    if (
      ![
        "event_seating_map",
        "goods_list",
        "key_visual",
        "product",
        "venue_generic_seating_map",
      ].includes(media.purpose)
    )
      continue;
    const id = await identity("mediaAsset", media.url);
    const scope: Scope = explicitPerformanceID
      ? { kind: "performances", performanceIDs: [explicitPerformanceID] }
      : { kind: "unconfirmed" };
    const kind = (
      {
        event_seating_map: "eventSeatingMap",
        goods_list: "goodsList",
        key_visual: "keyVisual",
        product: "product",
        venue_generic_seating_map: "venueGenericSeatingMap",
      } as const
    )[
      media.purpose as
        | "event_seating_map"
        | "goods_list"
        | "key_visual"
        | "product"
        | "venue_generic_seating_map"
    ];
    const previous = b.mediaAssets.find((m) => m.id === id);
    upsert("mediaAssets", {
      id,
      eventID,
      kind,
      originalURL: media.url,
      thumbnailURL: null,
      scope,
      sourceURL: snapshot.finalUrl,
      version: previous?.version ?? 1,
      caption: media.evidence.rawText,
      displayPolicy: "link_only",
    });
    const candidate: FactCandidate = {
      entityRef: media.entityRef,
      field: "media",
      value: media.url,
      applicability: media.applicability,
      sourceSnapshotId: snapshot.id,
      evidence: media.evidence,
      extractionMethod: "dom",
      parserVersion: parsed.adapterVersion ?? "unknown",
    };
    evidence(id, "kind", candidate, scope);
    evidence(id, "scope", candidate, scope);
  }
  return parseBundle(b);
}
