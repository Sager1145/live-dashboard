import type { CandidateLink, SourceAdapter, SourceSnapshot } from "../types.js";
import type { Cheerio, CheerioAPI } from "cheerio";
import type { AnyNode } from "domhandler";
import {
  absolute,
  baseResult,
  contextRef,
  fact,
  finish,
  load,
  media,
  parseJapaneseDateTimeWindow,
  PARSER_VERSION,
  selectedText,
  sourceKey,
  text,
  uniqueLinks,
} from "./common.js";

export const bushiroadLiveIndexAdapter: SourceAdapter = {
  id: "goods.bushiroad-live-index",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const matched =
      new URL(snapshot.finalUrl).hostname === "bushiroad-store.com" &&
      $(".blog-post-list .article-item").length > 0;
    return {
      matched,
      reason: matched
        ? "verified Shopify live article-list template"
        : "missing Bushiroad live article list",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $(".blog-post-list .article-item")
        .map((_i, node) => {
          const anchor = $(node).find(".article-item__title a[href]").first();
          const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
          if (!url) return undefined;
          return {
            url,
            title: text(anchor.text()),
            role: "goods" as const,
            sourceKey: sourceKey(url),
          };
        })
        .get()
        .filter(Boolean),
    );
  },
  extract(snapshot) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    result.links.push(...this.discover(snapshot));
    $(".blog-post-list .article-item").each((index, node) => {
      const anchor = $(node).find(".article-item__title a[href]").first();
      const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
      if (!url) return;
      const title = text(anchor.text());
      const ref = { sourceKey: sourceKey(url) };
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "goods.discoveryTitle",
          title,
          `.article-item:nth-of-type(${index + 1})`,
          title,
          ["live goods index"],
        ),
      );
      const image = $(node).find("img").first();
      const imageUrl = normalizeShopifyImage(
        absolute(
          image.attr("src") ?? image.attr("data-src") ?? "",
          snapshot.finalUrl,
        ),
      );
      if (imageUrl)
        result.media.push(
          media(
            ref,
            imageUrl,
            "goods_list",
            `.article-item:nth-of-type(${index + 1}) img`,
            title,
            ["live goods index"],
          ),
        );
    });
    result.sections.push({
      name: "live goods index",
      locator: ".blog-post-list .article-item",
      status: "parsed",
    });
    return finish(result);
  },
};

export const bushiroadLiveArticleAdapter: SourceAdapter = {
  id: "goods.bushiroad-live-article",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const matched =
      new URL(snapshot.finalUrl).hostname === "bushiroad-store.com" &&
      $("article[data-section-type='blog-post'] h1.page__title").length === 1;
    return {
      matched,
      reason: matched
        ? "verified Shopify blog-post template"
        : "missing Bushiroad blog-post article",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    const links: CandidateLink[] = $(
      "article[data-section-type='blog-post'] a[href]",
    )
      .map((_i, node) => {
        const url = absolute($(node).attr("href") ?? "", snapshot.finalUrl);
        if (!url) return undefined;
        const label = text($(node).text());
        return {
          url,
          title: label || undefined,
          role: /product|collection|pages/.test(new URL(url).pathname)
            ? ("product" as const)
            : ("unknown" as const),
        };
      })
      .get()
      .filter(Boolean);
    const scriptRedirect = snapshot.text.match(
      /window\.location\.replace\(["']([^"']+)["']\)/,
    )?.[1];
    if (scriptRedirect) {
      const url = absolute(scriptRedirect, snapshot.finalUrl);
      if (url) links.unshift({ url, role: "redirect" });
    }
    return uniqueLinks(links);
  },
  extract(snapshot, context) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    const ref = contextRef(context, snapshot.finalUrl);
    const title = text($("h1.page__title").first().text());
    const published = text($("time.page__meta-item--date").first().text());
    const content = $(".article__content.rte").first();
    const raw = text(content.text());
    result.links.push(...this.discover(snapshot));
    result.candidates.push(
      fact(
        snapshot,
        ref,
        "goods.officialName",
        title,
        "h1.page__title",
        title,
        ["goods article"],
      ),
    );
    if (published)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "goods.sourcePublishedDateRaw",
          published,
          "time.page__meta-item--date",
          published,
          ["goods article"],
        ),
      );
    if (!raw) {
      const redirect = result.links.find((link) => link.role === "redirect");
      result.sections.push({
        name: "article content",
        locator: ".article__content.rte",
        status: "empty",
      });
      result.issues.push({
        code: redirect ? "redirect_shell" : "empty_content",
        message: redirect
          ? `article is an empty redirect shell to ${redirect.url}`
          : "article body is empty",
        locator: ".article__content.rte",
        severity: "warning",
      });
      return finish(result);
    }
    result.candidates.push(
      fact(
        snapshot,
        ref,
        "goods.campaignRaw",
        raw,
        ".article__content.rte",
        raw,
        ["goods article"],
      ),
    );
    content.find("img").each((index, image) => {
      const url = normalizeShopifyImage(
        absolute(
          $(image).attr("src") ?? $(image).attr("data-src") ?? "",
          snapshot.finalUrl,
        ),
      );
      if (url)
        result.media.push(
          media(
            ref,
            url,
            "goods_list",
            `.article__content.rte img:nth-of-type(${index + 1})`,
            title,
            ["goods article"],
          ),
        );
    });
    result.sections.push({
      name: "article content",
      locator: ".article__content.rte",
      status: "parsed",
    });
    return finish(result);
  },
};

export const bushiroadStorePageAdapter: SourceAdapter = {
  id: "goods.bushiroad-page",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const url = new URL(snapshot.finalUrl);
    const matched =
      url.hostname === "bushiroad-store.com" &&
      url.pathname.startsWith("/pages/") &&
      $(".product-item").length > 0 &&
      $(".rte").filter((_i, node) => /通販期間/.test($(node).text())).length ===
        1;
    return {
      matched,
      reason: matched
        ? "verified Bushiroad campaign page with product cards"
        : "missing bounded campaign and product-card template",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $(".product-item a.product-item__title[href]")
        .map((_i, node) => {
          const url = absolute($(node).attr("href") ?? "", snapshot.finalUrl);
          return url
            ? {
                url,
                title: text($(node).text()),
                role: "product" as const,
                sourceKey: sourceKey(url),
              }
            : undefined;
        })
        .get()
        .filter(Boolean),
    );
  },
  extract(snapshot, context) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    const ref = contextRef(context, snapshot.finalUrl);
    const title = text(
      $("meta[property='og:title']").attr("content") ?? $("title").text(),
    );
    const campaign = $(".rte")
      .filter((_i, node) => /通販期間/.test($(node).text()))
      .first();
    const raw = text(campaign.text());
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "goods.officialName",
          title,
          "meta[property='og:title']",
          title,
          ["campaign"],
        ),
      );
    const campaignPrefix =
      raw.match(
        /(.+?通販実施いたします！.*?通販期間\s*)(.+?)(?=【法被】|お届け時期)/,
      )?.[2] ?? raw;
    const mainWindow = parseJapaneseDateTimeWindow(campaignPrefix);
    const shippingBlock = raw.match(/お届け時期\s*(.+?)(?=※|$)/)?.[1] ?? "";
    const mainShippingNote = text(shippingBlock.split(/【法被】/)[0] ?? "");
    const happiShippingNote = text(
      shippingBlock.match(/【法被】\s*(.+)$/)?.[1] ?? "",
    );
    const campaignKey = `${sourceKey(snapshot.finalUrl)}#campaign:main`;
    if (mainWindow.startAt)
      result.candidates.push(
        fact(
          snapshot,
          { ...ref, sourceKey: campaignKey },
          "goods.campaign",
          {
            sourceKey: campaignKey,
            officialName: title.replace(/｜.*$/, ""),
            channel: "online",
            fulfillment: "shipping",
            phase: "pre_event",
            salesStartAt: mainWindow.startAt,
            ...(mainWindow.endAt ? { salesEndAt: mainWindow.endAt } : {}),
            ...(mainShippingNote ? { shippingNote: mainShippingNote } : {}),
            url: snapshot.finalUrl,
            windowRaw: mainWindow.raw,
          },
          ".rte::campaign-main",
          campaignPrefix,
          ["campaign", "通販期間"],
        ),
      );
    const special = raw.match(/【法被】(.+?)(?=お届け時期)/);
    if (special) {
      const window = parseJapaneseDateTimeWindow(special[1]!);
      const key = `${sourceKey(snapshot.finalUrl)}#campaign:happi`;
      if (window.startAt)
        result.candidates.push(
          fact(
            snapshot,
            { ...ref, sourceKey: key },
            "goods.campaign",
            {
              sourceKey: key,
              officialName: "法被 通販",
              channel: "online",
              fulfillment: "shipping",
              phase: "pre_event",
              salesStartAt: window.startAt,
              ...(window.endAt ? { salesEndAt: window.endAt } : {}),
              ...(happiShippingNote ? { shippingNote: happiShippingNote } : {}),
              url: snapshot.finalUrl,
              windowRaw: window.raw,
            },
            ".rte::campaign-happi",
            special[0],
            ["campaign", "通販期間", "法被"],
          ),
        );
    }
    $(".product-item").each((index, node) => {
      const anchor = $(node).find("a.product-item__title[href]").first();
      const url = absolute(anchor.attr("href") ?? "", snapshot.finalUrl);
      const name = text(anchor.text());
      const itemRaw = text($(node).text());
      if (!url || !name) return;
      const price = itemRaw.match(/販売価格\s*([\d,]+)円/)?.[1];
      const stockStatus = /売切|在庫なし/.test(itemRaw)
        ? "sold_out"
        : /予約受付中/.test(itemRaw)
          ? "preorder"
          : /販売中/.test(itemRaw)
            ? "available"
            : undefined;
      const key = sourceKey(url);
      result.candidates.push(
        fact(
          snapshot,
          { ...ref, sourceKey: key },
          "goods.product",
          {
            sourceProductKey: key,
            campaignSourceKey:
              /法被/.test(name) && special
                ? `${sourceKey(snapshot.finalUrl)}#campaign:happi`
                : campaignKey,
            name,
            ...(price
              ? {
                  amount: {
                    minorUnits: Number(price.replaceAll(",", "")),
                    currency: "JPY",
                  },
                }
              : {}),
            url,
            variants: [],
            ...(stockStatus ? { stockStatus } : {}),
          },
          `.product-item:nth-of-type(${index + 1})`,
          itemRaw,
          ["products", name],
        ),
      );
      const image = $(node).find("img").first();
      const imageUrl = normalizeShopifyImage(
        absolute(
          image.attr("data-src") ?? image.attr("src") ?? "",
          snapshot.finalUrl,
        ),
      );
      if (imageUrl)
        result.media.push(
          media(
            { ...ref, sourceKey: key },
            imageUrl,
            "product",
            `.product-item:nth-of-type(${index + 1}) img`,
            itemRaw,
            ["products", name],
          ),
        );
    });
    result.links.push(...this.discover(snapshot));
    result.sections.push(
      { name: "campaign", locator: ".rte", status: "parsed" },
      { name: "products", locator: ".product-item", status: "parsed" },
    );
    return finish(result);
  },
};

export const schoolIdolStoreAdapter: SourceAdapter = {
  id: "goods.school-idol-store",
  version: PARSER_VERSION,
  matches(snapshot) {
    const $ = load(snapshot);
    const host = new URL(snapshot.finalUrl).hostname;
    const matched =
      [
        "lovelive.fannect.jp",
        "lovelive-store.bnfw.jp",
        "official-goods-store.jp",
      ].includes(host) &&
      ($("main").length > 0 || $("a[href*='lovelive.fannect.jp']").length > 0);
    return {
      matched,
      reason: matched
        ? "verified store portal/shell"
        : "unknown School idol STORE template",
    };
  },
  discover(snapshot) {
    const $ = load(snapshot);
    return uniqueLinks(
      $("main a[href], a[href*='lovelive.fannect.jp']")
        .map((_i, node) => {
          const url = absolute($(node).attr("href") ?? "", snapshot.finalUrl);
          if (!url) return undefined;
          const parsed = new URL(url);
          const role =
            /\/products?\//.test(parsed.pathname) ||
            parsed.hash.startsWith("#product-")
              ? ("product" as const)
              : parsed.hostname !== new URL(snapshot.finalUrl).hostname
                ? ("redirect" as const)
                : ("goods" as const);
          return {
            url,
            title:
              text($(node).text()) ||
              text($(node).find("img").attr("alt") ?? "") ||
              undefined,
            role,
            sourceKey: sourceKey(url),
          };
        })
        .get()
        .filter(Boolean),
    );
  },
  extract(snapshot, context) {
    const result = baseResult(this.id);
    const decision = this.matches(snapshot);
    if (!decision.matched) {
      result.issues.push({
        code: "unknown_template",
        message: decision.reason,
        severity: "error",
      });
      return finish(result);
    }
    const $ = load(snapshot);
    const ref = contextRef(context, snapshot.finalUrl);
    const title = text(
      $("meta[property='og:title']").attr("content") ?? $("title").text(),
    );
    if (title)
      result.candidates.push(
        fact(
          snapshot,
          ref,
          "goods.storeTitle",
          title,
          "meta[property='og:title']",
          title,
          ["store"],
        ),
      );
    if (new URL(snapshot.finalUrl).hostname === "lovelive.fannect.jp") {
      extractFannectCampaign($, snapshot, ref, result);
      extractFannectProducts($, snapshot, ref, result);
    }
    result.links.push(...this.discover(snapshot));
    result.sections.push({
      name: "store links",
      locator: "main a[href]",
      status: result.links.length ? "parsed" : "empty",
    });
    if (
      !result.links.length &&
      !result.candidates.some((candidate) =>
        candidate.field.startsWith("goods."),
      )
    )
      result.issues.push({
        code: "empty_content",
        message: "store template matched but exposed no candidate links",
        severity: "warning",
      });
    return finish(result);
  },
};

function extractFannectCampaign(
  $: CheerioAPI,
  snapshot: SourceSnapshot,
  ref: ReturnType<typeof contextRef>,
  result: ReturnType<typeof baseResult>,
): void {
  const pageTitle = text($("meta[property='og:title']").attr("content") ?? "");
  const eventHint = pageTitle.replace(/^【[^】]+】/, "");
  let selected: Cheerio<AnyNode> | undefined;
  let selectedIndex = -1;
  $(".sales-item").each((index, node) => {
    if (selected) return;
    const eventName = salesValue($, node, "公演名：");
    const reception = salesValue($, node, "受付名：");
    if (
      (eventName &&
        (eventName.includes(eventHint) || eventHint.includes(eventName))) ||
      (/アフターパンフレット/.test(pageTitle) &&
        /アフターパンフレット/.test(reception))
    ) {
      selected = $(node);
      selectedIndex = index;
    }
  });
  if (!selected) {
    extractFannectProductCampaign($, snapshot, ref, result);
    return;
  }
  const raw = text(selected.text());
  const officialName = salesValue($, selected[0]!, "受付名：");
  const eventName = salesValue($, selected[0]!, "公演名：");
  const windowRaw = salesValue($, selected[0]!, "受付期間：");
  const shippingNote = salesValue($, selected[0]!, "お届け時期：");
  const window = parseJapaneseDateTimeWindow(windowRaw);
  if (!officialName || !window.startAt) return;
  const key = `${sourceKey(snapshot.finalUrl)}#campaign`;
  const phase = /事後|アフター/.test(officialName) ? "post_event" : "pre_event";
  result.candidates.push(
    fact(
      snapshot,
      { ...ref, sourceKey: key },
      "goods.campaign",
      {
        sourceKey: key,
        officialName,
        eventName,
        channel: "online",
        fulfillment: "shipping",
        phase,
        salesStartAt: window.startAt,
        ...(window.endAt ? { salesEndAt: window.endAt } : {}),
        ...(shippingNote ? { shippingNote } : {}),
        url: snapshot.finalUrl,
        windowRaw,
      },
      `.sales-item:nth-of-type(${selectedIndex + 1})`,
      raw,
      ["sales schedule", officialName],
    ),
  );
}

function extractFannectProductCampaign(
  $: CheerioAPI,
  snapshot: SourceSnapshot,
  ref: ReturnType<typeof contextRef>,
  result: ReturnType<typeof baseResult>,
): void {
  const product = parseProductJson($);
  const description = $(".product__description").first();
  const raw = text(description.text());
  const windowRaw = raw.match(/【受付期間】\s*(.+?まで)/)?.[1];
  const publishedYear = product?.published_at?.match(/^(\d{4})-/)?.[1];
  if (
    !windowRaw ||
    !publishedYear ||
    !/アフターパンフレット/.test(product?.title ?? "")
  )
    return;
  const window = parseJapaneseDateTimeWindow(`${publishedYear}年${windowRaw}`);
  if (!window.startAt) return;
  const key = `${sourceKey(snapshot.finalUrl)}#campaign`;
  const shippingNote = raw.match(/本商品は公演後、(.+?お届け予定です)/)?.[1];
  result.candidates.push({
    ...fact(
      snapshot,
      { ...ref, sourceKey: key },
      "goods.campaign",
      {
        sourceKey: key,
        officialName: "アフターパンフレット",
        channel: "online",
        fulfillment: "shipping",
        phase: "post_event",
        salesStartAt: window.startAt,
        ...(window.endAt ? { salesEndAt: window.endAt } : {}),
        ...(shippingNote ? { shippingNote } : {}),
        url: snapshot.finalUrl,
        windowRaw,
      },
      ".product__description",
      raw,
      ["product", "受付期間"],
    ),
    extractionMethod: "structured_data",
  });
}

function salesValue($: CheerioAPI, node: AnyNode, label: string): string {
  return text(
    $(node)
      .find(".title")
      .filter((_i, item) => text($(item).text()) === label)
      .first()
      .next(".value")
      .text(),
  );
}

interface ShopifyVariant {
  id: number;
  price: number;
  public_title?: string | null;
  sku?: string;
}
interface ShopifyProduct {
  id: number;
  handle: string;
  variants: ShopifyVariant[];
}
interface ShopifyProductJson extends ShopifyProduct {
  title?: string;
  published_at?: string;
}

function extractFannectProducts(
  $: CheerioAPI,
  snapshot: SourceSnapshot,
  ref: ReturnType<typeof contextRef>,
  result: ReturnType<typeof baseResult>,
): void {
  const meta = parseShopifyMeta($);
  if (!meta) return;
  const products = meta.product ? [meta.product] : (meta.products ?? []);
  const campaignSourceKey = `${sourceKey(snapshot.finalUrl)}#campaign`;
  for (const product of products) {
    const url = absolute(`/products/${product.handle}`, snapshot.finalUrl)!;
    const item = $(".product-item")
      .filter((_i, node) => {
        const href =
          $(node).find("a[href*='/products/']").first().attr("href") ?? "";
        try {
          return new URL(href, snapshot.finalUrl).pathname.endsWith(
            `/products/${product.handle}`,
          );
        } catch {
          return false;
        }
      })
      .first();
    const titleNode = item.length
      ? item.find(".product-item__title").first()
      : $("h1.product__title").first();
    const name = text(titleNode.text());
    if (!name) continue;
    const rawNode = item.length ? item : $("main").first();
    const raw = text(rawNode.text());
    const status = /販売終了|売切|在庫なし/.test(raw)
      ? "sold_out"
      : /販売中|カートに追加/.test(raw)
        ? "available"
        : undefined;
    const variants = product.variants
      .filter((variant) => variant.public_title)
      .map((variant) => ({
        sourceVariantKey: String(variant.id),
        name: text(variant.public_title!),
        amount: {
          minorUnits: Math.round(variant.price / 100),
          currency: "JPY",
        },
        ...(variant.sku ? { sku: variant.sku } : {}),
      }));
    const prices = [
      ...new Set(
        product.variants.map((variant) => Math.round(variant.price / 100)),
      ),
    ];
    const purchaseLimit = raw.match(/1会計につき\s*\d+点まで/)?.[0];
    const key = `${sourceKey(url)}#product:${product.id}`;
    const value = {
      sourceProductKey: String(product.id),
      campaignSourceKey,
      name,
      ...(prices.length === 1
        ? { amount: { minorUnits: prices[0]!, currency: "JPY" } }
        : {}),
      url,
      variants,
      ...(purchaseLimit ? { purchaseLimit } : {}),
      ...(status ? { stockStatus: status } : {}),
    };
    const candidate = fact(
      snapshot,
      { ...ref, sourceKey: key },
      "goods.product",
      value,
      item.length
        ? `.product-item:has(a[href$='/products/${product.handle}'])`
        : "main .product",
      raw,
      ["products", name],
    );
    result.candidates.push({
      ...candidate,
      extractionMethod: "structured_data",
    });
    const image = rawNode.find("img").first();
    const imageUrl = absolute(
      image.attr("src") ?? image.attr("data-src") ?? "",
      snapshot.finalUrl,
    );
    if (imageUrl)
      result.media.push(
        media(
          { ...ref, sourceKey: key },
          imageUrl,
          "product",
          item.length
            ? `.product-item:has(a[href$='/products/${product.handle}']) img`
            : "main .product img",
          name,
          ["products", name],
        ),
      );
  }
  if (products.length)
    result.sections.push({
      name: "products",
      locator: ".product-item, main .product",
      status: "parsed",
    });
}

function parseProductJson($: CheerioAPI): ShopifyProductJson | undefined {
  const raw = $("script#ProductJson-product").first().text();
  if (!raw) return undefined;
  try {
    return JSON.parse(raw) as ShopifyProductJson;
  } catch {
    return undefined;
  }
}

function parseShopifyMeta(
  $: CheerioAPI,
): { product?: ShopifyProduct; products?: ShopifyProduct[] } | undefined {
  const script = $("script")
    .filter((_i, node) => $(node).text().includes("var meta = {"))
    .first()
    .text();
  const marker = "var meta = ";
  const start = script.indexOf(marker);
  if (start < 0) return undefined;
  const jsonStart = start + marker.length;
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (let index = jsonStart; index < script.length; index += 1) {
    const char = script[index]!;
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') quoted = false;
      continue;
    }
    if (char === '"') quoted = true;
    else if (char === "{") depth += 1;
    else if (char === "}" && --depth === 0) {
      try {
        return JSON.parse(script.slice(jsonStart, index + 1));
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

function normalizeShopifyImage(url: string | undefined): string | undefined {
  if (!url) return undefined;
  return url.replace("{width}x", "1200x").replace(/%7Bwidth%7Dx/i, "1200x");
}
