import { blobStoreFromEnv } from "./storage/index.js";
import Fastify, { type FastifyRequest } from "fastify";
import {
  createHash,
  createHmac,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { z, ZodError } from "zod";
import type { DB } from "./db.js";
import { reconcileInstallationNotifications } from "./notification-worker.js";
import {
  bundleSchema,
  catalogBootstrapSchema,
  compareDecimalCursor,
  identityMappingsSchema,
  mediaManifestSchema,
  metaSchema,
  parseBundle,
  parseBundleV2,
  parseCatalogChanges,
  updateJobAcceptedSchema,
  updateJobRequestSchema,
  updateJobStatusSchema,
  DomainError,
  type Bundle,
  type BundleV2,
} from "./contracts.js";
import { createReview, publishReview, withdrawEvent } from "./publisher.js";
import { enqueue } from "./queue.js";

const digest = (s: string) => createHash("sha256").update(s).digest("hex");
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const emptyAliases = () => ({
  events: [] as { legacyID: string; currentID: string }[],
  performances: [] as { legacyID: string; currentID: string }[],
  tickets: [] as { legacyID: string; currentID: string }[],
  goods: [] as { legacyID: string; currentID: string }[],
});
function decimalString(value: unknown): string {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value))
      throw new DomainError(500, "Catalog cursor lost precision");
    return String(value);
  }
  if (typeof value === "string" && DECIMAL.test(value)) return value;
  throw new DomainError(500, "Catalog cursor lost precision");
}
function jsonValue<T>(value: unknown): T {
  return (typeof value === "string" ? JSON.parse(value) : value) as T;
}
function pngSize(bytes: Buffer) {
  const magic = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (
    bytes.length < 24 ||
    !bytes.subarray(0, 8).equals(magic) ||
    bytes.subarray(12, 16).toString("ascii") !== "IHDR"
  )
    return undefined;
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}
function positiveInt(value: unknown) {
  if (typeof value === "bigint") {
    if (value <= 0n || value > BigInt(Number.MAX_SAFE_INTEGER)) return undefined;
    return Number(value);
  }
  if (typeof value === "number")
    return Number.isSafeInteger(value) && value > 0 ? value : undefined;
  if (typeof value === "string" && /^[1-9][0-9]*$/.test(value)) {
    const parsed = Number(value);
    return Number.isSafeInteger(parsed) ? parsed : undefined;
  }
  return undefined;
}
function canonicalTarget(
  target: z.infer<typeof updateJobRequestSchema>["target"],
) {
  switch (target.kind) {
    case "catalog":
      return JSON.stringify({ kind: "catalog" });
    case "source":
      return JSON.stringify({ kind: "source", sourceID: target.sourceID });
    case "event":
      return JSON.stringify({ kind: "event", eventID: target.eventID });
    case "eventSection":
      return JSON.stringify({
        kind: "eventSection",
        eventID: target.eventID,
        section: target.section,
      });
    case "card":
      return JSON.stringify({
        kind: "card",
        eventID: target.eventID,
        cardID: target.cardID,
      });
    case "history":
      return JSON.stringify({ kind: "history", eventID: target.eventID });
  }
}
async function assertUpdateTarget(
  tx: DB,
  target: z.infer<typeof updateJobRequestSchema>["target"],
) {
  if (target.kind === "catalog") return;
  if (target.kind === "source") {
    if (!z.uuid().safeParse(target.sourceID).success)
      throw new DomainError(422, "Unknown source");
    const row = (
      await tx.query("SELECT id FROM source_origins WHERE id=$1", [
        target.sourceID,
      ])
    ).rows[0];
    if (!row) throw new DomainError(422, "Unknown source");
    return;
  }
  const event = (
    await tx.query("SELECT id FROM events WHERE id=$1 AND NOT deleted", [
      target.eventID,
    ])
  ).rows[0];
  if (!event) throw new DomainError(422, "Unknown event");
  if (target.kind !== "card") return;
  const card = (
    await tx.query(
      "SELECT id FROM scoped_records WHERE id=$1 AND event_id=$2",
      [target.cardID, target.eventID],
    )
  ).rows[0];
  if (!card) throw new DomainError(422, "Unknown card");
}
const pageTokenSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("bootstrap"),
    snapshotID: z.string().min(1).max(200),
    watermark: z.string().regex(DECIMAL),
    after: z.string().max(200),
    limit: z.number().int().min(1).max(500),
  }),
  z.object({
    kind: z.literal("changes"),
    watermark: z.string().regex(DECIMAL),
    after: z.string().regex(DECIMAL),
    limit: z.number().int().min(1).max(500),
  }),
]);
const equal = (a: string, b: string) =>
  timingSafeEqual(Buffer.from(digest(a)), Buffer.from(digest(b)));
const escape = (v: unknown) =>
  String(v ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const html = (title: string, body: string) =>
  `<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)} · Live Dashboard</title><style>body{font:16px system-ui;margin:40px auto;padding:0 24px;max-width:1200px;color:#172b35;background:#f5f7f8}a{color:#146276}nav{display:flex;gap:24px;margin-bottom:32px}table{border-collapse:collapse;width:100%;background:white}td,th{padding:12px;text-align:left;border-bottom:1px solid #ddd;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}textarea{width:100%;min-height:300px}button{padding:10px 20px;margin:8px;background:#146276;color:white;border:0;border-radius:8px}input{padding:10px}article{background:white;border-radius:12px;padding:24px;margin:16px 0}.columns{display:grid;grid-template-columns:1fr 1fr;gap:20px}.status{color:#536775}</style><nav><a href="/admin">审核</a><a href="/admin/sources">来源健康</a><a href="/admin/events">发布版本</a><a href="/admin/operations">任务与通知</a><a href="/admin/settings">设置</a><a href="/admin/reports">纠错</a></nav><h1>${escape(title)}</h1>${body}</html>`;
function bearer(req: FastifyRequest) {
  return req.headers.authorization?.startsWith("Bearer ")
    ? req.headers.authorization.slice(7)
    : "";
}
async function sourceHealthMap(
  db: DB,
): Promise<Record<string, Bundle["sourceHealth"]>> {
  const rows = (
    await db.query(`SELECT e.id,d.health,d.last_snapshot_id FROM events e
 LEFT JOIN LATERAL jsonb_array_elements(e.bundle->'evidence') fact ON true
 LEFT JOIN source_snapshots s ON s.id::text=fact->>'snapshotID'
 LEFT JOIN source_documents d ON d.id=s.document_id WHERE NOT e.deleted`)
  ).rows;
  const result: Record<string, Bundle["sourceHealth"]> = {};
  const rank = {
    healthy: 0,
    stale: 1,
    fetch_failed: 2,
    blocked: 3,
    parse_failed: 4,
  };
  for (const r of rows) {
    const health: Bundle["sourceHealth"] =
      r.health === "parse_failed"
        ? "parse_failed"
        : r.health === "blocked"
          ? "blocked"
          : r.health === "fetch_failed"
            ? "fetch_failed"
            : r.health === "healthy"
              ? "healthy"
              : "stale";
    if (!result[r.id] || rank[health] > rank[result[r.id]!])
      result[r.id] = health;
  }
  return result;
}
export function createApp(
  db: DB,
  options: {
    adminToken: string;
    logger?: boolean;
    metaRateLimit?: { limit: number; windowMs: number };
  },
) {
  if (options.adminToken.length < 24)
    throw new Error("ADMIN_TOKEN must have at least 24 characters");
  const app = Fastify({
    logger: options.logger ?? false,
    bodyLimit: 6 * 1024 * 1024,
    trustProxy: false,
  });
  const csrf = randomBytes(32).toString("hex");
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string" },
    (_req, body, done) =>
      done(null, Object.fromEntries(new URLSearchParams(String(body)))),
  );
  app.setErrorHandler((error, req, reply) => {
    if (error instanceof ZodError)
      return reply
        .code(422)
        .send({ error: "validation_failed", issues: error.issues });
    const status = (error as any).statusCode ?? 500;
    if (status >= 500) req.log.error(error);
    return reply.code(status).send({
      error: status >= 500 ? "internal_error" : (error as Error).message,
    });
  });
  app.addHook("onRequest", async (req, reply) => {
    reply
      .header("X-Content-Type-Options", "nosniff")
      .header("Referrer-Policy", "no-referrer");
    if (req.url.startsWith("/admin")) {
      let token = bearer(req);
      if (req.headers.authorization?.startsWith("Basic ")) {
        const decoded = Buffer.from(
          req.headers.authorization.slice(6),
          "base64",
        ).toString();
        token = decoded.slice(decoded.indexOf(":") + 1);
      }
      if (!equal(token, options.adminToken))
        return reply
          .header("WWW-Authenticate", 'Basic realm="Live Dashboard Admin"')
          .code(401)
          .send({ error: "Admin authentication required" });
      reply
        .header("Cache-Control", "no-store")
        .header(
          "Content-Security-Policy",
          "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        );
    }
  });
  app.addHook("preHandler", async (req) => {
    if (req.url.startsWith("/admin") && req.method !== "GET" && !bearer(req)) {
      if (!equal(String((req.body as any)?.csrf ?? ""), csrf))
        throw new DomainError(403, "Invalid form token");
    }
  });
  const form = (action: string, label: string, extra = "") =>
    `<form method="post" action="${escape(action)}"><input type="hidden" name="csrf" value="${csrf}">${extra}<input name="reason" required placeholder="审核／更正原因"><button>${escape(label)}</button></form>`;
  const adminReason = (req: FastifyRequest) =>
    z.object({ reason: z.string().trim().min(1).max(2000) }).parse(req.body)
      .reason;
  async function installation(req: FastifyRequest) {
    const id = z.uuid().parse((req.params as any).id);
    const row = (
      await db.query("SELECT * FROM installations WHERE id=$1", [id])
    ).rows[0];
    if (!row || !equal(digest(bearer(req)), row.credential_hash))
      throw new DomainError(401, "Invalid installation credential");
    return row;
  }
  const pageSecret = randomBytes(32);
  const metaHits = new Map<string, { count: number; reset: number }>();
  const metaLimit = options.metaRateLimit ?? { limit: 60, windowMs: 60_000 };
  let cachedInstanceID: string | undefined;
  function limitMeta(req: FastifyRequest) {
    const now = Date.now();
    const key = req.ip || "local";
    const hit = metaHits.get(key);
    if (!hit || hit.reset <= now) {
      metaHits.set(key, { count: 1, reset: now + metaLimit.windowMs });
      return;
    }
    hit.count += 1;
    if (hit.count > metaLimit.limit) throw new DomainError(429, "rate_limited");
  }
  function signPage(body: z.infer<typeof pageTokenSchema>) {
    const payload = Buffer.from(JSON.stringify(body)).toString("base64url");
    const sig = createHmac("sha256", pageSecret)
      .update(payload)
      .digest("base64url");
    return `${payload}.${sig}`;
  }
  function readPage(token: string, kind: "bootstrap" | "changes") {
    const dot = token.indexOf(".");
    if (dot <= 0) throw new DomainError(400, "Invalid page token");
    const payload = token.slice(0, dot);
    const sig = token.slice(dot + 1);
    const expected = createHmac("sha256", pageSecret)
      .update(payload)
      .digest("base64url");
    if (!equal(sig, expected)) throw new DomainError(400, "Invalid page token");
    let parsed: unknown;
    try {
      parsed = JSON.parse(Buffer.from(payload, "base64url").toString());
    } catch {
      throw new DomainError(400, "Invalid page token");
    }
    const result = pageTokenSchema.safeParse(parsed);
    if (!result.success || result.data.kind !== kind)
      throw new DomainError(400, "Invalid page token");
    return result.data;
  }
  async function serverInstanceID() {
    if (cachedInstanceID) return cachedInstanceID;
    const existing = (
      await db.query(
        "SELECT target FROM audit_log WHERE action='server_instance' ORDER BY created_at, id LIMIT 1",
      )
    ).rows[0];
    if (existing) {
      cachedInstanceID = String(existing.target);
      return cachedInstanceID;
    }
    const id = randomUUID();
    await db.query(
      "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'system','server_instance',$2,'stable catalog instance')",
      [randomUUID(), id],
    );
    const winner = (
      await db.query(
        "SELECT target FROM audit_log WHERE action='server_instance' ORDER BY created_at, id LIMIT 1",
      )
    ).rows[0];
    cachedInstanceID = String(winner.target);
    return cachedInstanceID;
  }
  async function installationRole(id: string) {
    const row = (
      await db.query(
        "SELECT target FROM audit_log WHERE actor=$1 AND action='installation_role' ORDER BY created_at DESC LIMIT 1",
        [id],
      )
    ).rows[0];
    return row?.target === "owner" ? "owner" : "receiver";
  }
  async function ownerInstallation(token: string) {
    if (!token) return undefined;
    const row = (
      await db.query(
        "SELECT * FROM installations WHERE credential_hash=$1",
        [digest(token)],
      )
    ).rows[0];
    if (!row) return undefined;
    return (await installationRole(row.id)) === "owner" ? row : undefined;
  }
  async function requireOwner(req: FastifyRequest) {
    const token = bearer(req);
    if (!token) throw new DomainError(401, "Owner authentication required");
    if (equal(token, options.adminToken)) return "admin";
    const owner = await ownerInstallation(token);
    if (owner) return String(owner.id);
    const installation = (
      await db.query("SELECT id FROM installations WHERE credential_hash=$1", [
        digest(token),
      ])
    ).rows[0];
    if (installation) throw new DomainError(403, "Owner authentication required");
    throw new DomainError(401, "Owner authentication required");
  }
  async function variantFacts(hashes: string[], tx: DB = db) {
    const facts = new Map<
      string,
      { contentType: string; byteSize: number; width: number; height: number }
    >();
    if (!hashes.length) return facts;
    const rows = (
      await tx.query(
        "SELECT content_hash, media_type, byte_size, width, height, blob_key FROM media_versions WHERE content_hash = ANY($1::text[])",
        [[...new Set(hashes)]],
      )
    ).rows;
    const store = blobStoreFromEnv();
    for (const row of rows) {
      let width = positiveInt(row.width);
      let height = positiveInt(row.height);
      if ((!width || !height) && store && row.blob_key) {
        try {
          const sniffed = pngSize(await store.read(row.blob_key));
          width = width || sniffed?.width;
          height = height || sniffed?.height;
        } catch {
          /* unresolved dimensions are not invented */
        }
      }
      const byteSize = positiveInt(row.byte_size);
      if (!width || !height || byteSize === undefined) continue;
      facts.set(String(row.content_hash), {
        contentType: String(row.media_type),
        byteSize,
        width,
        height,
      });
    }
    return facts;
  }
  function manifestFromAssets(
    raw: any,
    facts: Awaited<ReturnType<typeof variantFacts>>,
  ) {
    if (raw.mediaManifest) return raw.mediaManifest;
    const assets = (raw.mediaAssets ?? []).map((asset: any, order: number) => {
      const downloadable =
        asset.displayPolicy === "permitted_cache" ||
        asset.displayPolicy === "permitted_remote_display";
      const fact =
        typeof asset.contentHash === "string"
          ? facts.get(asset.contentHash)
          : undefined;
      if (downloadable && !fact)
        throw new DomainError(422, "Published media is missing verified bytes");
      const sourceReferenceID =
        raw.evidence?.find((entry: any) => entry.recordID === asset.id)
          ?.snapshotID ??
        raw.evidence?.[0]?.snapshotID ??
        asset.id;
      return {
        assetID: asset.id,
        logicalImageID: asset.id,
        role: asset.kind,
        order,
        scope: asset.scope,
        displayPolicy: asset.displayPolicy ?? "link_only",
        state: "ready",
        variants: fact
          ? {
              original: {
                contentHash: asset.contentHash,
                path: `/v2/assets/${asset.contentHash}/original`,
                contentType: fact.contentType,
                width: fact.width,
                height: fact.height,
                byteSize: fact.byteSize,
              },
            }
          : {},
        sourceReferenceID,
      };
    });
    return {
      eventID: raw.event.id,
      revision: raw.revision ?? 0,
      assets,
    };
  }
  async function publishableV2(raw: any, tx: DB = db): Promise<BundleV2> {
    const hashes = (raw.mediaAssets ?? [])
      .map((asset: any) => asset.contentHash)
      .filter((hash: unknown): hash is string => typeof hash === "string");
    const facts = await variantFacts(hashes, tx);
    return parseBundleV2({
      ...raw,
      schemaVersion: 2,
      sourceCheckedAt: raw.sourceCheckedAt ?? raw.publishedAt,
      performances: (raw.performances ?? []).map((performance: any) => {
        const { localTime, ...rest } = performance;
        return { ...rest, localTime: localTime ?? null };
      }),
      fieldAbsences: raw.fieldAbsences ?? [],
      applicability: raw.applicability ?? [],
      legacyAliases: raw.legacyAliases ?? emptyAliases(),
      mediaManifest: raw.mediaManifest ?? manifestFromAssets(raw, facts),
    });
  }
  function headerValue(req: FastifyRequest, name: string) {
    const value = req.headers[name];
    return Array.isArray(value) ? (value[0] ?? "") : (value ?? "");
  }
  function jobView(row: any) {
    const payload = jsonValue<any>(row.payload) ?? {};
    const cancelled =
      payload.state === "cancelled" || row.last_error === "cancelled";
    const state = cancelled
      ? "cancelled"
      : row.status === "queued"
        ? "queued"
        : row.status === "running"
          ? "running"
          : row.status === "done"
            ? payload.state === "partial"
              ? "partial"
              : "succeeded"
            : "failed";
    const progress = payload.progress ?? {
      sectionsCompleted: 0,
      sectionsTotal: 0,
      assetsReady: 0,
      assetsTotal: 0,
    };
    const issues = Array.isArray(payload.issues) ? payload.issues : [];
    if (
      state === "failed" &&
      typeof row.last_error === "string" &&
      /^[A-Z0-9_]{1,80}$/.test(row.last_error)
    )
      issues.push({ code: row.last_error });
    return updateJobStatusSchema.parse({
      jobID: String(row.id),
      state,
      progress,
      published: Array.isArray(payload.published) ? payload.published : [],
      issues,
    });
  }
  async function clock(tx: DB) {
    const row = (
      await tx.query(
        "SELECT value, minimum_cursor FROM catalog_clock WHERE singleton=true",
      )
    ).rows[0];
    return {
      value: decimalString(row.value),
      minimum: decimalString(row.minimum_cursor),
    };
  }
  app.get("/health", async () => {
    await db.query("SELECT 1");
    return { status: "ok" };
  });
  app.get("/v1/catalog/bootstrap", async () =>
    db.transaction(async (tx) => {
      await tx.query(
        "SELECT value FROM catalog_clock WHERE singleton=true FOR SHARE",
      );
      const clock = (
        await tx.query("SELECT value FROM catalog_clock WHERE singleton=true")
      ).rows[0];
      const health = await sourceHealthMap(tx);
      const events = (
        await tx.query(
          "SELECT bundle FROM events WHERE NOT deleted ORDER BY id",
        )
      ).rows.map((r) => ({
        ...r.bundle,
        sourceHealth: health[r.bundle.event.id] ?? "stale",
      }));
      return { schemaVersion: 1, cursor: String(clock.value), events };
    }),
  );
  app.get("/v1/catalog/changes", async (req) => {
    const q = z
      .object({
        cursor: z.string().regex(/^\d+$/),
        limit: z.coerce.number().int().min(1).max(500).default(100),
      })
      .parse(req.query);
    return db.transaction(async (tx) => {
      await tx.query(
        "SELECT value FROM catalog_clock WHERE singleton=true FOR SHARE",
      );
      const clock = (
        await tx.query("SELECT * FROM catalog_clock WHERE singleton=true")
      ).rows[0];
      if (BigInt(q.cursor) < BigInt(clock.minimum_cursor))
        throw new DomainError(410, "cursor_expired");
      if (BigInt(q.cursor) > BigInt(clock.value))
        throw new DomainError(400, "Cursor exceeds catalog");
      const rows = (
        await tx.query(
          "SELECT * FROM catalog_changes WHERE sequence>$1 AND sequence<=$2 ORDER BY sequence LIMIT $3",
          [q.cursor, clock.value, q.limit],
        )
      ).rows;
      return {
        sourceHealth: await sourceHealthMap(tx),
        cursor: String(rows.at(-1)?.sequence ?? q.cursor),
        hasMore:
          rows.length > 0 &&
          BigInt(rows.at(-1)!.sequence) < BigInt(clock.value),
        changes: rows.map((r) => ({
          sequence: String(r.sequence),
          eventID: r.event_id,
          revision: r.revision,
          kind: r.kind,
          bundle: r.bundle ?? undefined,
          replacementID: r.replacement_id ?? undefined,
        })),
      };
    });
  });
  app.get("/v1/events", async (req) => {
    const q = z
      .object({
        franchise: z.enum(["bangdream", "lovelive"]).optional(),
        group: z.string().optional(),
        type: z.string().optional(),
        from: z.iso.date().optional(),
        to: z.iso.date().optional(),
        after: z.string().default(""),
        limit: z.coerce.number().int().min(1).max(100).default(30),
      })
      .parse(req.query);
    const rows = (
      await db.query(
        "SELECT id,bundle FROM events WHERE NOT deleted AND id>$1 ORDER BY id",
        [q.after],
      )
    ).rows;
    const hits = rows.flatMap((r) => {
      const b = r.bundle as Bundle;
      if (
        (q.franchise && b.event.franchise !== q.franchise) ||
        (q.type && b.event.eventType !== q.type)
      )
        return [];
      const matched = b.performances.filter(
        (p) =>
          (!q.group || p.performers.includes(q.group)) &&
          (!q.from || (p.localDate !== null && p.localDate >= q.from)) &&
          (!q.to || (p.localDate !== null && p.localDate <= q.to)),
      );
      return matched.length
        ? [{ ...b, matchingPerformanceIDs: matched.map((p) => p.id) }]
        : [];
    });
    const events = hits.slice(0, q.limit);
    return {
      events,
      nextCursor: hits.length > q.limit ? events.at(-1)!.event.id : null,
    };
  });
  app.get("/v1/events/:id", async (req, reply) => {
    const row = (
      await db.query("SELECT * FROM events WHERE id=$1 AND NOT deleted", [
        (req.params as any).id,
      ])
    ).rows[0];
    if (!row) throw new DomainError(404, "Event not found");
    const health = (await sourceHealthMap(db))[row.id] ?? "stale";
    const etag = `"${row.content_hash}-${health}"`;
    reply.header("ETag", etag);
    if (req.headers["if-none-match"] === etag) return reply.code(304).send();
    return { ...row.bundle, sourceHealth: health };
  });
  app.get("/v1/events/:id/changes", async (req) => ({
    changes: (
      await db.query(
        'SELECT revision,reason,published_at AS "publishedAt" FROM event_revisions WHERE event_id=$1 ORDER BY revision DESC LIMIT 100',
        [(req.params as any).id],
      )
    ).rows,
  }));
  app.get("/v1/media/:id", async (req) => {
    const row = (
      await db.query(
        "SELECT r.data FROM scoped_records r JOIN events e ON e.id=r.event_id WHERE r.id=$1 AND r.kind='mediaAsset' AND NOT e.deleted",
        [(req.params as any).id],
      )
    ).rows[0];
    if (!row) throw new DomainError(404, "Media not found");
    return row.data;
  });
  app.get("/v1/media/:id/content", async (req, reply) => {
    const id = (req.params as any).id;
    const row = (
      await db.query(
        "SELECT r.data,m.blob_key,m.media_type,m.content_hash FROM scoped_records r JOIN events e ON e.id=r.event_id JOIN media_versions m ON m.asset_id=r.id AND m.version=(r.data->>'version')::integer AND m.content_hash=r.data->>'contentHash' WHERE r.id=$1 AND r.kind='mediaAsset' AND NOT e.deleted AND r.data->>'displayPolicy'='permitted_cache'",
        [id],
      )
    ).rows[0];
    const store = blobStoreFromEnv();
    if (!row || !store)
      throw new DomainError(404, "Published cached media not found");
    const etag = `"${row.content_hash}"`;
    reply
      .header("ETag", etag)
      .header("Cache-Control", "public, max-age=3600")
      .header("Content-Security-Policy", "default-src 'none'; sandbox");
    if (req.headers["if-none-match"] === etag) return reply.code(304).send();
    return reply.type(row.media_type).send(await store.read(row.blob_key));
  });
  app.get("/v1/evidence/:id", async (req) => {
    const row = (
      await db.query(
        "SELECT a.evidence FROM accepted_facts a JOIN events e ON e.id=a.event_id AND e.revision=a.revision WHERE a.evidence->>'id'=$1 AND NOT e.deleted",
        [(req.params as any).id],
      )
    ).rows[0];
    if (!row) throw new DomainError(404, "Evidence not found");
    return { ...row.evidence, quote: row.evidence.quote.slice(0, 500) };
  });
  app.post("/v1/installations", async (_req, reply) => {
    const id = randomUUID(),
      credential = randomBytes(32).toString("base64url");
    await db.query(
      "INSERT INTO installations(id,credential_hash) VALUES($1,$2)",
      [id, digest(credential)],
    );
    return reply.code(201).send({ id, credential });
  });
  for (const path of [
    "/v1/installations/:id/push-token",
    "/v2/installations/:id/push-token",
  ])
  app.put(path, async (req) => {
    const row = await installation(req);
    const b = z
      .object({
        token: z.string().regex(/^[0-9a-f]{64,200}$/i),
        environment: z.enum(["sandbox", "production"]),
      })
      .parse(req.body);
    await db.transaction(async (tx) => {
      await tx.query(
        "UPDATE installations SET push_token=$2,environment=$3 WHERE id=$1",
        [row.id, b.token, b.environment],
      );
      await reconcileInstallationNotifications(tx, row.id);
    });
    return { ok: true };
  });
  for (const path of [
    "/v1/installations/:id/subscriptions",
    "/v2/installations/:id/subscriptions",
  ])
  app.put(path, async (req) => {
    const row = await installation(req);
    const body = z
      .object({
        subscriptions: z
          .array(
            z.object({
              eventID: z.string(),
              performanceIDs: z.array(z.string()).default([]),
              changesEnabled: z.boolean().default(true),
            }),
          )
          .max(500),
      })
      .parse(req.body);
    await db.transaction(async (tx) => {
      await tx.query("DELETE FROM subscriptions WHERE installation_id=$1", [
        row.id,
      ]);
      for (const s of body.subscriptions) {
        const event = (
          await tx.query(
            "SELECT bundle FROM events WHERE id=$1 AND NOT deleted",
            [s.eventID],
          )
        ).rows[0];
        if (
          !event ||
          s.performanceIDs.some(
            (id) => !event.bundle.performances.some((p: any) => p.id === id),
          )
        )
          throw new DomainError(422, "Unknown event/performance");
        await tx.query(
          "INSERT INTO subscriptions(installation_id,event_id,performance_ids,changes_enabled) VALUES($1,$2,$3,$4)",
          [
            row.id,
            s.eventID,
            JSON.stringify(s.performanceIDs),
            s.changesEnabled,
          ],
        );
      }
      await tx.query(
        "UPDATE notification_deliveries SET status='cancelled',lease_until=null,lease_token=null WHERE installation_id=$1 AND status IN('pending','retry','sending')",
        [row.id],
      );
      await reconcileInstallationNotifications(tx, row.id);
    });
    return { ok: true };
  });
  for (const path of [
    "/v1/installations/:id/reminders",
    "/v2/installations/:id/reminders",
  ])
  app.put(path, async (req) => {
    const row = await installation(req);
    const body = z
      .object({
        reminders: z
          .array(
            z.object({
              eventID: z.string(),
              performanceID: z.string(),
              recordID: z.string(),
              field: z.enum(["applyEndAt", "paymentDeadlineAt"]),
              leadSeconds: z.number().int().min(0).max(2592000),
              enabled: z.boolean().default(true),
            }),
          )
          .max(500),
      })
      .parse(req.body);
    await db.transaction(async (tx) => {
      const retained: string[] = [];
      for (const r of body.reminders) {
        const b = (
          await tx.query(
            "SELECT bundle FROM events WHERE id=$1 AND NOT deleted",
            [r.eventID],
          )
        ).rows[0]?.bundle;
        if (
          !b ||
          !b.performances.some((p: any) => p.id === r.performanceID) ||
          !b.ticketRounds.some((t: any) => t.id === r.recordID)
        )
          throw new DomainError(422, "Unknown reminder target");
        const round = b.ticketRounds.find((t: any) => t.id === r.recordID);
        if (
          r.enabled &&
          (round.status !== "confirmed" ||
            round.scope.kind !== "performances" ||
            !round.scope.performanceIDs.includes(r.performanceID) ||
            !round[r.field])
        )
          throw new DomainError(
            422,
            "Reminder requires a confirmed deadline in the selected performance",
          );
        const saved = (
          await tx.query(
            "INSERT INTO reminders(id,installation_id,event_id,performance_id,record_id,field,lead_seconds,enabled) VALUES($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT(installation_id,event_id,performance_id,record_id,field) DO UPDATE SET lead_seconds=EXCLUDED.lead_seconds,enabled=EXCLUDED.enabled RETURNING id",
            [
              randomUUID(),
              row.id,
              r.eventID,
              r.performanceID,
              r.recordID,
              r.field,
              r.leadSeconds,
              r.enabled,
            ],
          )
        ).rows[0];
        retained.push(saved.id);
      }
      await tx.query(
        "DELETE FROM reminders WHERE installation_id=$1 AND NOT (id=ANY($2::uuid[]))",
        [row.id, retained],
      );
      await tx.query(
        "UPDATE notification_deliveries SET status='cancelled',lease_until=null,lease_token=null WHERE installation_id=$1 AND status IN('pending','retry','sending') AND payload->>'category'='deadline'",
        [row.id],
      );
      await reconcileInstallationNotifications(tx, row.id);
    });
    return { ok: true };
  });
  app.delete("/v1/installations/:id", async (req) => {
    const row = await installation(req);
    await db.query("DELETE FROM installations WHERE id=$1", [row.id]);
    return { deleted: true };
  });
  app.get("/v2/meta", async (req) => {
    limitMeta(req);
    return metaSchema.parse({
      serverInstanceID: await serverInstanceID(),
      schemaVersions: [1, 2],
      capabilities: [
        "catalog",
        "events",
        "media",
        "evidence",
        "identity-mappings",
        "pairings",
        "installations",
        "update-jobs",
      ],
    });
  });
  app.get("/v2/catalog/bootstrap", async (req) => {
    const query = z
      .object({
        page: z.string().min(1).optional(),
        limit: z.coerce.number().int().min(1).max(500).default(100),
      })
      .parse(req.query);
    const instanceID = await serverInstanceID();
    return db.transaction(async (tx) => {
      await tx.query(
        "SELECT value FROM catalog_clock WHERE singleton=true FOR SHARE",
      );
      const current = await clock(tx);
      const opened = query.page
        ? readPage(query.page, "bootstrap")
        : undefined;
      const token = opened?.kind === "bootstrap" ? opened : undefined;
      const watermark = token?.watermark ?? current.value;
      const limit = token?.limit ?? query.limit;
      const after = token?.after ?? "";
      if (compareDecimalCursor(watermark, current.value) > 0)
        throw new DomainError(400, "Cursor exceeds catalog");
      if (compareDecimalCursor(watermark, current.minimum) < 0)
        throw new DomainError(410, "cursor_expired");
      const snapshotID = token?.snapshotID ?? randomUUID();
      const health = await sourceHealthMap(tx);
      const rows = (
        await tx.query(
          `WITH latest AS (
             SELECT DISTINCT ON (event_id) event_id, kind, bundle
             FROM catalog_changes
             WHERE sequence <= $1::bigint
             ORDER BY event_id, sequence DESC
           )
           SELECT event_id, bundle FROM latest
           WHERE kind='upsert' AND bundle IS NOT NULL AND event_id > $2
           ORDER BY event_id
           LIMIT $3`,
          [watermark, after, limit + 1],
        )
      ).rows;
      const hasMore = rows.length > limit;
      const page = rows.slice(0, limit);
      const events = [];
      for (const row of page)
        events.push(
          await publishableV2(
            {
              ...row.bundle,
              sourceHealth: health[row.event_id] ?? "stale",
            },
            tx,
          ),
        );
      return catalogBootstrapSchema.parse({
        schemaVersion: 2,
        serverInstanceID: instanceID,
        snapshotID,
        cursor: watermark,
        watermark,
        hasMore,
        nextPageToken: hasMore
          ? signPage({
              kind: "bootstrap",
              snapshotID,
              watermark,
              after: String(page[page.length - 1]!.event_id),
              limit,
            })
          : null,
        events,
      });
    });
  });
  app.get("/v2/catalog/changes", async (req) => {
    const query = z
      .object({
        cursor: z.string().regex(DECIMAL).optional(),
        page: z.string().min(1).optional(),
        limit: z.coerce.number().int().min(1).max(500).default(100),
      })
      .parse(req.query);
    if (!query.cursor && !query.page)
      throw new DomainError(400, "cursor required");
    const instanceID = await serverInstanceID();
    return db.transaction(async (tx) => {
      await tx.query(
        "SELECT value FROM catalog_clock WHERE singleton=true FOR SHARE",
      );
      const current = await clock(tx);
      const opened = query.page ? readPage(query.page, "changes") : undefined;
      const token = opened?.kind === "changes" ? opened : undefined;
      const fromCursor = token?.after ?? query.cursor!;
      const watermark = token?.watermark ?? current.value;
      const limit = token?.limit ?? query.limit;
      if (
        compareDecimalCursor(fromCursor, current.minimum) < 0 ||
        compareDecimalCursor(watermark, current.minimum) < 0
      )
        throw new DomainError(410, "cursor_expired");
      if (
        compareDecimalCursor(fromCursor, current.value) > 0 ||
        compareDecimalCursor(watermark, current.value) > 0
      )
        throw new DomainError(400, "Cursor exceeds catalog");
      const rows = (
        await tx.query(
          "SELECT * FROM catalog_changes WHERE sequence > $1::bigint AND sequence <= $2::bigint ORDER BY sequence LIMIT $3",
          [fromCursor, watermark, limit],
        )
      ).rows;
      const health = await sourceHealthMap(tx);
      const changes = [];
      for (const row of rows) {
        const sequence = decimalString(row.sequence);
        if (row.kind === "upsert") {
          if (!row.bundle)
            throw new DomainError(422, "Unknown catalog change");
          const bundle = await publishableV2(
            {
              ...row.bundle,
              sourceHealth: health[row.event_id] ?? "stale",
            },
            tx,
          );
          if (
            bundle.event.id !== row.event_id ||
            bundle.revision !== row.revision
          )
            throw new DomainError(422, "Unknown catalog change");
          changes.push({
            sequence,
            kind: "upsert" as const,
            eventID: row.event_id,
            revision: bundle.revision,
            bundle,
          });
        } else if (row.kind === "delete") {
          changes.push({
            sequence,
            kind: "delete" as const,
            eventID: row.event_id,
            revision: row.revision,
          });
        } else if (row.kind === "remap" && row.replacement_id) {
          changes.push({
            sequence,
            kind: "remap" as const,
            entityKind: "event" as const,
            legacyID: row.event_id,
            currentID: row.replacement_id,
          });
        } else throw new DomainError(422, "Unknown catalog change");
      }
      const last = changes.at(-1)?.sequence ?? fromCursor;
      const more = (
        await tx.query(
          "SELECT sequence FROM catalog_changes WHERE sequence > $1::bigint AND sequence <= $2::bigint ORDER BY sequence LIMIT 1",
          [last, watermark],
        )
      ).rows.length > 0;
      const cursor = more ? last : watermark;
      return parseCatalogChanges({
        schemaVersion: 2,
        serverInstanceID: instanceID,
        fromCursor,
        cursor,
        watermark,
        hasMore: more,
        nextPageToken: more
          ? signPage({
              kind: "changes",
              watermark,
              after: cursor,
              limit,
            })
          : null,
        changes,
        sourceHealth: health,
      });
    });
  });
  app.get("/v2/events", async (req) => {
    const q = z
      .object({
        franchise: z.enum(["bangdream", "lovelive"]).optional(),
        group: z.string().optional(),
        type: z.string().optional(),
        from: z.iso.date().optional(),
        to: z.iso.date().optional(),
        after: z.string().default(""),
        limit: z.coerce.number().int().min(1).max(100).default(30),
      })
      .parse(req.query);
    const rows = (
      await db.query(
        "SELECT id,bundle FROM events WHERE NOT deleted AND id>$1 ORDER BY id",
        [q.after],
      )
    ).rows;
    const health = await sourceHealthMap(db);
    const hits = [];
    for (const row of rows) {
      const raw = row.bundle as Bundle;
      if (
        (q.franchise && raw.event.franchise !== q.franchise) ||
        (q.type && raw.event.eventType !== q.type)
      )
        continue;
      const matched = raw.performances.filter(
        (performance) =>
          (!q.group || performance.performers.includes(q.group)) &&
          (!q.from ||
            (performance.localDate !== null &&
              performance.localDate >= q.from)) &&
          (!q.to ||
            (performance.localDate !== null && performance.localDate <= q.to)),
      );
      if (!matched.length) continue;
      hits.push({
        ...(await publishableV2({
          ...raw,
          sourceHealth: health[raw.event.id] ?? "stale",
        })),
        matchingPerformanceIDs: matched.map((performance) => performance.id),
      });
    }
    const events = hits.slice(0, q.limit);
    return {
      events,
      nextCursor: hits.length > q.limit ? events.at(-1)!.event.id : null,
    };
  });
  app.get("/v2/events/:id", async (req, reply) => {
    const row = (
      await db.query("SELECT * FROM events WHERE id=$1 AND NOT deleted", [
        (req.params as any).id,
      ])
    ).rows[0];
    if (!row) throw new DomainError(404, "Event not found");
    const health = (await sourceHealthMap(db))[row.id] ?? "stale";
    const etag = `"${row.content_hash}-${health}"`;
    reply.header("ETag", etag);
    if (req.headers["if-none-match"] === etag) return reply.code(304).send();
    return publishableV2({ ...row.bundle, sourceHealth: health });
  });
  app.get("/v2/events/:id/changes", async (req) => ({
    changes: (
      await db.query(
        'SELECT revision,reason,published_at AS "publishedAt" FROM event_revisions WHERE event_id=$1 ORDER BY revision DESC LIMIT 100',
        [(req.params as any).id],
      )
    ).rows,
  }));
  app.get("/v2/events/:id/media", async (req) => {
    const params = z
      .object({
        id: z.string().min(1),
        revision: z.coerce.number().int().positive().optional(),
      })
      .parse({ ...(req.params as object), ...(req.query as object) });
    const row = params.revision
      ? (
          await db.query(
            "SELECT bundle FROM event_revisions WHERE event_id=$1 AND revision=$2",
            [params.id, params.revision],
          )
        ).rows[0]
      : (
          await db.query(
            "SELECT bundle FROM events WHERE id=$1 AND NOT deleted",
            [params.id],
          )
        ).rows[0];
    if (!row) throw new DomainError(404, "Event not found");
    return mediaManifestSchema.parse(
      (await publishableV2(row.bundle)).mediaManifest,
    );
  });
  app.get("/v2/assets/:hash/:variant", async (req, reply) => {
    const params = z
      .object({
        hash: z.string().regex(/^[a-f0-9]{64}$/),
        variant: z.enum(["original", "preview"]),
      })
      .safeParse(req.params);
    if (!params.success)
      throw new DomainError(404, "Published asset not found");
    const rows = (
      await db.query(
        "SELECT bundle FROM events WHERE NOT deleted AND position($1 in bundle::text) > 0",
        [params.data.hash],
      )
    ).rows;
    let assetID: string | undefined;
    let version: number | undefined;
    for (const row of rows) {
      const raw = row.bundle;
      const manifest = raw.mediaManifest?.assets ?? [];
      for (const asset of manifest) {
        const variant = asset.variants?.[params.data.variant];
        if (
          variant?.contentHash === params.data.hash &&
          asset.displayPolicy === "permitted_cache" &&
          asset.state === "ready"
        ) {
          assetID = asset.logicalImageID;
          break;
        }
      }
      if (assetID) break;
      if (params.data.variant !== "original") continue;
      for (const asset of raw.mediaAssets ?? []) {
        if (
          asset.contentHash === params.data.hash &&
          asset.displayPolicy === "permitted_cache"
        ) {
          assetID = asset.id;
          version = asset.version;
          break;
        }
      }
      if (assetID) break;
    }
    const store = blobStoreFromEnv();
    if (!assetID || !store)
      throw new DomainError(404, "Published asset not found");
    const media = (
      await db.query(
        version
          ? "SELECT blob_key, media_type, content_hash FROM media_versions WHERE content_hash=$1 AND asset_id=$2 AND version=$3"
          : "SELECT blob_key, media_type, content_hash FROM media_versions WHERE content_hash=$1 AND ($2::text IS NULL OR asset_id=$2) ORDER BY version DESC LIMIT 1",
        version
          ? [params.data.hash, assetID, version]
          : [params.data.hash, assetID],
      )
    ).rows[0];
    if (!media) throw new DomainError(404, "Published asset not found");
    const etag = `"${media.content_hash}"`;
    reply
      .header("ETag", etag)
      .header("Cache-Control", "public, max-age=3600")
      .header("Content-Security-Policy", "default-src 'none'; sandbox");
    if (req.headers["if-none-match"] === etag) return reply.code(304).send();
    return reply.type(media.media_type).send(await store.read(media.blob_key));
  });
  app.get("/v2/evidence/:id", async (req) => {
    const row = (
      await db.query(
        "SELECT a.evidence FROM accepted_facts a JOIN events e ON e.id=a.event_id AND e.revision=a.revision WHERE a.evidence->>'id'=$1 AND NOT e.deleted",
        [(req.params as any).id],
      )
    ).rows[0];
    if (!row) throw new DomainError(404, "Evidence not found");
    const evidence = row.evidence;
    return {
      id: evidence.id,
      recordID: evidence.recordID,
      field: evidence.field,
      sourceURL: evidence.sourceURL,
      quote: String(evidence.quote ?? "").slice(0, 500),
      snapshotID: evidence.snapshotID,
      locator: evidence.locator,
      sourcePublishedAt: evidence.sourcePublishedAt ?? null,
      observedAt: evidence.observedAt,
      verifiedAt: evidence.verifiedAt,
      verification: evidence.verification,
      adapterVersion: evidence.adapterVersion,
      performanceIDs: evidence.performanceIDs ?? [],
    };
  });
  app.get("/v2/identity-mappings", async () => {
    const rows = (
      await db.query("SELECT bundle FROM events WHERE NOT deleted ORDER BY id")
    ).rows;
    const seen = new Map<string, string>();
    const mappings: {
      entityKind: "event" | "performance" | "ticket" | "goods";
      legacyID: string;
      currentID: string;
    }[] = [];
    for (const row of rows) {
      const aliases = row.bundle.legacyAliases ?? emptyAliases();
      const groups = [
        ["event", aliases.events],
        ["performance", aliases.performances],
        ["ticket", aliases.tickets],
        ["goods", aliases.goods],
      ] as const;
      for (const [entityKind, list] of groups) {
        for (const alias of list ?? []) {
          const key = `${entityKind}:${alias.legacyID}`;
          const prior = seen.get(key);
          if (prior && prior !== alias.currentID)
            throw new DomainError(422, "Legacy ID maps to two current IDs");
          if (prior) continue;
          seen.set(key, alias.currentID);
          mappings.push({
            entityKind,
            legacyID: alias.legacyID,
            currentID: alias.currentID,
          });
        }
      }
    }
    return identityMappingsSchema.parse({
      serverInstanceID: await serverInstanceID(),
      mappings,
    });
  });
  app.post("/v2/pairings/complete", async (req, reply) => {
    const body = z
      .object({
        token: z.string().min(20).max(300),
        challenge: z.string().min(20).max(300),
      })
      .parse(req.body);
    const created = await db.transaction(async (tx) => {
      const row = (
        await tx.query(
          "SELECT * FROM jobs WHERE kind='pairing' AND dedupe_key=$1 FOR UPDATE",
          [digest(body.token)],
        )
      ).rows[0];
      const payload = row ? jsonValue<any>(row.payload) : undefined;
      if (
        !row ||
        row.status !== "queued" ||
        !payload ||
        !equal(digest(body.challenge), payload.challengeHash) ||
        Date.parse(payload.expires) <= Date.now()
      )
        throw new DomainError(401, "Pairing token is invalid");
      const id = randomUUID();
      const credential = randomBytes(32).toString("base64url");
      const role = payload.role === "owner" ? "owner" : "receiver";
      await tx.query(
        "INSERT INTO installations(id,credential_hash) VALUES($1,$2)",
        [id, digest(credential)],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,$2,'installation_role',$3,'pairing')",
        [randomUUID(), id, role],
      );
      await tx.query(
        "UPDATE jobs SET status='done',lease_until=null WHERE id=$1 AND status='queued'",
        [row.id],
      );
      return { id, credential, role };
    });
    return reply.code(201).send(created);
  });
  app.post("/v2/auth/refresh", async (req) => {
    const token = bearer(req);
    if (!token) throw new DomainError(401, "Invalid installation credential");
    const credential = randomBytes(32).toString("base64url");
    const row = (
      await db.query(
        "UPDATE installations SET credential_hash=$2 WHERE credential_hash=$1 RETURNING id",
        [digest(token), digest(credential)],
      )
    ).rows[0];
    if (!row) throw new DomainError(401, "Invalid installation credential");
    return { id: row.id, credential };
  });
  app.delete("/v2/installations/:id", async (req) => {
    const id = z.uuid().parse((req.params as any).id);
    const token = bearer(req);
    if (!token) throw new DomainError(401, "Invalid installation credential");
    if (equal(token, options.adminToken) || (await ownerInstallation(token))) {
      const row = (
        await db.query("SELECT id FROM installations WHERE id=$1", [id])
      ).rows[0];
      if (!row) throw new DomainError(404, "Installation not found");
      await db.query("DELETE FROM installations WHERE id=$1", [id]);
      return { deleted: true };
    }
    const row = (
      await db.query("SELECT * FROM installations WHERE id=$1", [id])
    ).rows[0];
    if (!row || !equal(digest(token), row.credential_hash))
      throw new DomainError(401, "Invalid installation credential");
    await db.query("DELETE FROM installations WHERE id=$1", [id]);
    return { deleted: true };
  });
  app.post("/v2/update-jobs", async (req, reply) => {
    const owner = await requireOwner(req);
    const idempotencyKey = headerValue(req, "idempotency-key").trim();
    if (!idempotencyKey || idempotencyKey.length > 200)
      throw new DomainError(400, "Idempotency-Key required");
    const request = updateJobRequestSchema.parse(req.body);
    const canonical = JSON.stringify(request);
    const activeKey = digest(canonicalTarget(request.target));
    const accepted = await db.transaction(async (tx) => {
      await tx.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
        `v2-update:${activeKey}`,
      ]);
      await assertUpdateTarget(tx, request.target);
      const existing = (
        await tx.query(
          "SELECT * FROM jobs WHERE kind='v2-update' AND payload->'keys' ? $1 FOR UPDATE",
          [idempotencyKey],
        )
      ).rows[0];
      if (existing) {
        const payload = jsonValue<any>(existing.payload);
        if (payload.requestCanonical !== canonical)
          throw new DomainError(
            409,
            "Idempotency key was reused with a different request",
          );
        return updateJobAcceptedSchema.parse(payload.accepted[idempotencyKey]);
      }
      const active = (
        await tx.query(
          "SELECT * FROM jobs WHERE kind='v2-update' AND status IN ('queued','running') AND payload->>'activeKey'=$1 FOR UPDATE",
          [activeKey],
        )
      ).rows[0];
      if (active) {
        const payload = jsonValue<any>(active.payload);
        const body = {
          jobID: String(active.id),
          state: "queued" as const,
          deduplicated: true,
          statusPath: `/v2/update-jobs/${active.id}`,
        };
        payload.keys.push(idempotencyKey);
        payload.accepted[idempotencyKey] = body;
        await tx.query("UPDATE jobs SET payload=$2 WHERE id=$1", [
          active.id,
          JSON.stringify(payload),
        ]);
        return updateJobAcceptedSchema.parse(body);
      }
      const jobID = randomUUID();
      const body = {
        jobID,
        state: "queued" as const,
        deduplicated: false,
        statusPath: `/v2/update-jobs/${jobID}`,
      };
      await tx.query(
        "INSERT INTO jobs(id,kind,payload,dedupe_key,status) VALUES($1,'v2-update',$2,$3,'queued')",
        [
          jobID,
          JSON.stringify({
            request,
            requestCanonical: canonical,
            activeKey,
            keys: [idempotencyKey],
            accepted: { [idempotencyKey]: body },
            state: "queued",
            progress: {
              sectionsCompleted: 0,
              sectionsTotal: 0,
              assetsReady: 0,
              assetsTotal: 0,
            },
            published: [],
            issues: [],
            owner,
          }),
          `v2:${digest(idempotencyKey)}`,
        ],
      );
      return updateJobAcceptedSchema.parse(body);
    });
    return reply.code(202).send(accepted);
  });
  app.get("/v2/update-jobs/:id", async (req) => {
    await requireOwner(req);
    const row = (
      await db.query("SELECT * FROM jobs WHERE id=$1 AND kind='v2-update'", [
        z.uuid().parse((req.params as any).id),
      ])
    ).rows[0];
    if (!row) throw new DomainError(404, "Job not found");
    return jobView(row);
  });
  app.post("/v2/update-jobs/:id/cancel", async (req) => {
    await requireOwner(req);
    const id = z.uuid().parse((req.params as any).id);
    return db.transaction(async (tx) => {
      const row = (
        await tx.query(
          "SELECT * FROM jobs WHERE id=$1 AND kind='v2-update' FOR UPDATE",
          [id],
        )
      ).rows[0];
      if (!row) throw new DomainError(404, "Job not found");
      if (row.status !== "queued" && row.status !== "running")
        throw new DomainError(409, "Job can no longer be cancelled");
      const payload = jsonValue<any>(row.payload);
      payload.state = "cancelled";
      const updated = (
        await tx.query(
          "UPDATE jobs SET status='failed',last_error='cancelled',payload=$2,lease_until=null,fencing_token=null WHERE id=$1 AND status IN ('queued','running') RETURNING *",
          [id, JSON.stringify(payload)],
        )
      ).rows[0];
      if (!updated) throw new DomainError(409, "Job can no longer be cancelled");
      return jobView(updated);
    });
  });
  app.post("/v1/reports", async (req, reply) => {
    const b = z
      .object({
        eventID: z.string().optional(),
        body: z.string().trim().min(10).max(3000),
      })
      .parse(req.body);
    const id = randomUUID();
    await db.query("INSERT INTO reports(id,event_id,body) VALUES($1,$2,$3)", [
      id,
      b.eventID ?? null,
      b.body,
    ]);
    return reply.code(201).send({ id });
  });
  app.get("/admin", async (_req, reply) => {
    const cases = (
      await db.query(
        "SELECT * FROM review_cases ORDER BY created_at DESC LIMIT 100",
      )
    ).rows;
    return reply
      .type("text/html")
      .send(
        html(
          "审核队列",
          `<p>候选不能直接修改公共资料。关键字段发布前核对原文、适用场次及基础版本。</p><table><tr><th>公演</th><th>状态</th><th>基础版本</th></tr>${cases.map((r) => `<tr><td><a href="/admin/reviews/${r.id}">${escape(r.proposal.event.officialTitle)}</a></td><td>${escape(r.status)}</td><td>${r.base_revision}</td></tr>`).join("")}</table><article><h2>提交人工更正／候选快照</h2>${form("/admin/reviews", "提交审核", '<label>基础版本 <input name="baseRevision" type="number" min="0" value="0"></label><textarea name="proposal" required placeholder="LiveEventBundle JSON（带来源快照证据）"></textarea>')}</article>`,
        ),
      );
  });
  app.post("/admin/reviews", async (req, reply) => {
    const raw = req.body as any;
    const proposal =
      typeof raw.proposal === "string"
        ? JSON.parse(raw.proposal)
        : raw.proposal;
    const r = await createReview(
      db,
      proposal,
      z.coerce.number().int().nonnegative().parse(raw.baseRevision),
    );
    if (bearer(req)) return reply.code(201).send(r);
    return reply.redirect(`/admin/reviews/${r.id}`);
  });
  app.get("/admin/reviews/:id", async (req, reply) => {
    const r = (
      await db.query("SELECT * FROM review_cases WHERE id=$1", [
        (req.params as any).id,
      ])
    ).rows[0];
    if (!r) throw new DomainError(404, "Review not found");
    const old = (
      await db.query("SELECT bundle FROM events WHERE id=$1", [r.event_id])
    ).rows[0]?.bundle;
    return reply.type("text/html").send(
      html(
        "版本与证据对比",
        `<p>状态 ${escape(r.status)} · 基础版本 ${r.base_revision}</p><div class="columns"><article><h2>已发布</h2><pre>${escape(JSON.stringify(old ?? null, null, 2))}</pre></article><article><h2>候选与证据</h2><pre>${escape(JSON.stringify(r.proposal, null, 2))}</pre><pre>${escape(JSON.stringify(r.issues, null, 2))}</pre></article></div><p>${[...new Set((r.proposal.evidence as any[]).map((e) => e.snapshotID))].map((id) => `<a href="/admin/snapshots/${escape(id)}">原始快照 ${escape(id)}</a>`).join(" · ")}</p>${(
          r.proposal.mediaAssets as any[]
        )
          .filter((m) => m.contentHash)
          .map(
            (m) =>
              `<p><a href="/admin/media/${encodeURIComponent(m.id)}/versions/${m.version}">核对媒体 v${m.version}：${escape(m.caption ?? m.kind)}</a></p>`,
          )
          .join(
            "",
          )}${r.status === "pending" ? form(`/admin/reviews/${r.id}/edit`, "保存候选并重新核验", `<label>编辑范围、关联与候选字段（Bundle JSON）<textarea name="proposal" required>${escape(JSON.stringify(r.proposal, null, 2))}</textarea></label>`) + form(`/admin/reviews/${r.id}/verify`, "已核对全部字段、原文与适用场次") + form(`/admin/reviews/${r.id}/publish`, "核验通过并发布") + form(`/admin/reviews/${r.id}/reject`, "拒绝候选") : ""}`,
      ),
    );
  });
  app.get("/admin/media/:id/versions/:version", async (req, reply) => {
    const params = z
      .object({ id: z.string(), version: z.coerce.number().int().positive() })
      .parse(req.params);
    const media = (
      await db.query(
        "SELECT * FROM media_versions WHERE asset_id=$1 AND version=$2",
        [params.id, params.version],
      )
    ).rows[0];
    const store = blobStoreFromEnv();
    if (!media || !store) throw new DomainError(404, "Media version not found");
    reply.header("Content-Security-Policy", "default-src 'none'; sandbox");
    if (media.media_type === "application/pdf")
      reply.header("Content-Disposition", 'attachment; filename="review.pdf"');
    return reply.type(media.media_type).send(await store.read(media.blob_key));
  });
  app.get("/admin/snapshots/:id", async (req, reply) => {
    const s = (
      await db.query("SELECT * FROM source_snapshots WHERE id=$1", [
        (req.params as any).id,
      ])
    ).rows[0];
    if (!s) throw new DomainError(404, "Snapshot not found");
    return reply
      .type("text/html")
      .send(
        html(
          "原始快照（转义文本）",
          `<pre>${escape(JSON.stringify(s.metadata, null, 2))}</pre><pre>${escape(s.body)}</pre>`,
        ),
      );
  });
  app.post("/admin/reviews/:id/edit", async (req, reply) => {
    const reason = adminReason(req);
    const id = (req.params as any).id;
    const raw = (req.body as any).proposal;
    const proposal = parseBundle(
      typeof raw === "string" ? JSON.parse(raw) : raw,
    );
    await db.transaction(async (tx) => {
      const r = (
        await tx.query("SELECT * FROM review_cases WHERE id=$1 FOR UPDATE", [
          id,
        ])
      ).rows[0];
      if (!r || r.status !== "pending")
        throw new DomainError(409, "Review is not pending");
      if (proposal.event.id !== r.event_id)
        throw new DomainError(422, "A proposal cannot change event identity");
      proposal.evidence = proposal.evidence.map((e) => ({
        ...e,
        verification: "needsReview",
      }));
      for (const record of [
        ...proposal.ticketRounds,
        ...proposal.streamOffers,
        ...proposal.goodsCampaigns,
      ])
        if (record.status === "confirmed") record.status = "needsReview";
      await tx.query(
        "UPDATE review_cases SET proposal=$2,reviewer=null,reason=$3 WHERE id=$1",
        [id, JSON.stringify(proposal), reason],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','edit_proposal',$2,$3)",
        [randomUUID(), id, reason],
      );
    });
    return bearer(req)
      ? { updated: true, requiresVerification: true }
      : reply.redirect(`/admin/reviews/${id}`);
  });
  app.post("/admin/reviews/:id/verify", async (req, reply) => {
    const reason = adminReason(req);
    const id = (req.params as any).id;
    await db.transaction(async (tx) => {
      const r = (
        await tx.query("SELECT * FROM review_cases WHERE id=$1 FOR UPDATE", [
          id,
        ])
      ).rows[0];
      if (!r || r.status !== "pending")
        throw new DomainError(409, "Review is not pending");
      const b = bundleSchema.parse(r.proposal);
      b.evidence = b.evidence.map((e) => ({
        ...e,
        verification: "confirmed",
        verifiedAt: new Date().toISOString(),
      }));
      for (const record of [
        ...b.ticketRounds,
        ...b.streamOffers,
        ...b.goodsCampaigns,
      ])
        if (record.status === "needsReview") record.status = "confirmed";
      await tx.query(
        "UPDATE review_cases SET proposal=$2,reviewer=$3,reason=$4 WHERE id=$1",
        [id, JSON.stringify(b), "admin", reason],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','verify',$2,$3)",
        [randomUUID(), id, reason],
      );
    });
    return bearer(req)
      ? { verified: true }
      : reply.redirect(`/admin/reviews/${id}`);
  });
  app.post("/admin/reviews/:id/publish", async (req, reply) => {
    const result = await publishReview(
      db,
      (req.params as any).id,
      "admin",
      adminReason(req),
    );
    return bearer(req) ? result : reply.redirect("/admin");
  });
  app.post("/admin/reviews/:id/reject", async (req, reply) => {
    await db.query(
      "UPDATE review_cases SET status='rejected',reason=$2,reviewer='admin',resolved_at=now() WHERE id=$1 AND status='pending'",
      [(req.params as any).id, adminReason(req)],
    );
    return bearer(req) ? { ok: true } : reply.redirect("/admin");
  });
  app.get("/admin/events", async (_req, reply) => {
    const rows = (
      await db.query(
        "SELECT id,revision,bundle,deleted FROM events ORDER BY updated_at DESC",
      )
    ).rows;
    return reply
      .type("text/html")
      .send(
        html(
          "已发布公演",
          rows
            .map(
              (r) =>
                `<article><h2>${escape(r.bundle.event.officialTitle)}</h2><p>${escape(r.id)} · v${r.revision} ${r.deleted ? "已撤回" : ""}</p>${form(`/admin/events/${encodeURIComponent(r.id)}/rollback`, "创建回滚审核", '<input name="revision" type="number" min="1" required placeholder="历史版本">')}${form(`/admin/events/${encodeURIComponent(r.id)}/withdraw`, "确认撤回", `<input type="hidden" name="baseRevision" value="${r.revision}"><input name="replacementID" placeholder="合并后的公演 ID（可选）">`)}</article>`,
            )
            .join(""),
        ),
      );
  });
  app.post("/admin/events/:id/rollback", async (req, reply) => {
    const id = (req.params as any).id;
    const revision = z.coerce
      .number()
      .int()
      .positive()
      .parse((req.body as any).revision);
    adminReason(req);
    const old = (
      await db.query(
        "SELECT bundle FROM event_revisions WHERE event_id=$1 AND revision=$2",
        [id, revision],
      )
    ).rows[0];
    if (!old) throw new DomainError(404, "Revision not found");
    const current = (
      await db.query("SELECT revision FROM events WHERE id=$1", [id])
    ).rows[0];
    const r = await createReview(db, old.bundle, current.revision, [
      {
        message: `Rollback requested to v${revision}`,
        reason: adminReason(req),
      },
    ]);
    return bearer(req) ? r : reply.redirect(`/admin/reviews/${r.id}`);
  });
  app.post("/admin/events/:id/withdraw", async (req, reply) => {
    const body = req.body as any;
    const result = await withdrawEvent(
      db,
      (req.params as any).id,
      z.coerce.number().int().positive().parse(body.baseRevision),
      "admin",
      adminReason(req),
      body.replacementID || undefined,
    );
    return bearer(req) ? result : reply.redirect("/admin/events");
  });
  app.get("/admin/sources", async (_req, reply) => {
    const rows = (
      await db.query("SELECT * FROM source_origins ORDER BY origin")
    ).rows;
    const docs = (
      await db.query("SELECT * FROM source_documents ORDER BY identity_url")
    ).rows;
    return reply
      .type("text/html")
      .send(
        html(
          "来源健康与策略",
          `${rows.map((r) => `<article><h2>${escape(r.origin)}</h2><p>${escape(r.health)} · 最近成功 ${escape(r.last_success_at)}</p><pre>${escape(JSON.stringify(r.policy, null, 2))}</pre>${form(`/admin/sources/${r.id}/pause`, "暂停来源")}${form(`/admin/sources/${r.id}/policy`, "保存已审核来源策略", `<textarea name="policy" required>${escape(JSON.stringify(r.policy, null, 2))}</textarea>`)}</article>`).join("")}<table><tr><th>文档</th><th>健康</th><th>抓取控制</th></tr>${docs.map((d) => `<tr><td>${escape(d.fetch_url)}</td><td>${escape(d.health)}</td><td>${d.enabled ? "已启用" : "待审"}${form(`/admin/documents/${d.id}/enabled`, d.enabled ? "停用文档" : "启用文档", `<input type="hidden" name="enabled" value="${!d.enabled}">`)}${d.enabled ? form(`/admin/documents/${d.id}/fetch`, "立即抓取") : ""}</td></tr>`).join("")}</table>`,
        ),
      );
  });
  app.post("/admin/sources/:id/pause", async (req, reply) => {
    adminReason(req);
    await db.query(
      "UPDATE source_origins SET policy=jsonb_set(policy,'{enabled}','false'::jsonb) WHERE id=$1",
      [(req.params as any).id],
    );
    return bearer(req) ? { ok: true } : reply.redirect("/admin/sources");
  });
  app.post("/admin/sources/:id/policy", async (req, reply) => {
    const reason = adminReason(req);
    const raw = (req.body as any).policy;
    const policy = z
      .object({
        id: z.string(),
        host: z.string(),
        enabled: z.boolean(),
        reviewStatus: z.enum(["pending_review", "approved", "rejected"]),
        allowedPaths: z.array(z.string().startsWith("/")).min(1),
        robotsCheckedAt: z.iso.datetime({ offset: true }).optional(),
        termsReviewedAt: z.iso.datetime({ offset: true }).optional(),
      })
      .passthrough()
      .parse(typeof raw === "string" ? JSON.parse(raw) : raw);
    if (
      policy.enabled &&
      (policy.reviewStatus !== "approved" ||
        !policy.robotsCheckedAt ||
        !policy.termsReviewedAt)
    )
      throw new DomainError(
        422,
        "Enabled sources require dated robots and terms review",
      );
    const id = (req.params as any).id;
    await db.transaction(async (tx) => {
      const origin = (
        await tx.query(
          "SELECT origin FROM source_origins WHERE id=$1 FOR UPDATE",
          [id],
        )
      ).rows[0];
      if (!origin) throw new DomainError(404, "Source not found");
      if (new URL(origin.origin).hostname !== policy.host)
        throw new DomainError(422, "Policy host does not match source origin");
      await tx.query("UPDATE source_origins SET policy=$2 WHERE id=$1", [
        id,
        JSON.stringify(policy),
      ]);
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','source_policy',$2,$3)",
        [randomUUID(), id, reason],
      );
    });
    return bearer(req) ? { updated: true } : reply.redirect("/admin/sources");
  });
  app.post("/admin/documents/:id/enabled", async (req, reply) => {
    const reason = adminReason(req);
    const enabled =
      z.enum(["true", "false"]).parse(String((req.body as any).enabled)) ===
      "true";
    const id = (req.params as any).id;
    await db.transaction(async (tx) => {
      const row = (
        await tx.query(
          "SELECT d.id,o.policy FROM source_documents d JOIN source_origins o ON o.id=d.origin_id WHERE d.id=$1 FOR UPDATE OF d",
          [id],
        )
      ).rows[0];
      if (!row) throw new DomainError(404, "Document not found");
      if (
        enabled &&
        (!row.policy.enabled || row.policy.reviewStatus !== "approved")
      )
        throw new DomainError(422, "Source policy must be approved first");
      await tx.query(
        "UPDATE source_documents SET enabled=$2,next_fetch_at=now() WHERE id=$1",
        [id, enabled],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','document_enabled',$2,$3)",
        [randomUUID(), id, reason],
      );
    });
    return bearer(req) ? { enabled } : reply.redirect("/admin/sources");
  });
  app.post("/admin/documents/:id/fetch", async (req, reply) => {
    const reason = adminReason(req);
    const id = z.uuid().parse((req.params as any).id);
    const document = (
      await db.query(
        "SELECT d.enabled,o.policy FROM source_documents d JOIN source_origins o ON o.id=d.origin_id WHERE d.id=$1",
        [id],
      )
    ).rows[0];
    if (!document) throw new DomainError(404, "Document not found");
    if (
      !document.enabled ||
      document.policy.enabled !== true ||
      document.policy.reviewStatus !== "approved"
    )
      throw new DomainError(422, "Enable and approve this source first");
    const jobID = await enqueue(db, "fetch", { documentID: id }, `manual:fetch:${id}:${randomUUID()}`);
    await db.query(
      "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','manual_fetch',$2,$3)",
      [randomUUID(), id, reason],
    );
    return bearer(req) ? { jobID } : reply.redirect("/admin/operations");
  });
  app.get("/admin/settings", async (_req, reply) => {
    const enabled =
      (await db.query("SELECT value FROM app_settings WHERE key='scraping_enabled'"))
        .rows[0]?.value !== false;
    const currentIP = process.env.API_BIND_IP ?? "127.0.0.1";
    const choices = (process.env.API_NETWORK_CHOICES ?? currentIP)
      .split(",")
      .filter((ip) => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip));
    const preferredIP = (
      await db.query("SELECT value FROM app_settings WHERE key='preferred_bind_ip'")
    ).rows[0]?.value as string | undefined;
    return reply.type("text/html").send(
      html(
        "服务设置",
        `<article><h2>抓取总开关</h2><p>当前：${enabled ? "运行中" : "已暂停"}。暂停后不再领取抓取和解析任务；正在执行的任务会完成。来源逐项开关仍在<a href="/admin/sources">来源健康</a>。</p>${form("/admin/settings/scraping", enabled ? "暂停抓取" : "恢复抓取", `<input type="hidden" name="enabled" value="${!enabled}">`)}</article><article><h2>网络</h2><p>当前绑定：${escape(currentIP)}:${escape(process.env.API_PORT ?? "3000")}。选择树莓派网卡地址后，在树莓派执行 <code>git deploy-pi</code> 应用。127.0.0.1 仅通过本机或 SSH 隧道访问。</p>${form("/admin/settings/network", "保存网络地址", `<label>服务地址 <select name="bindIP">${choices.map((ip) => `<option value="${escape(ip)}" ${ip === (preferredIP ?? currentIP) ? "selected" : ""}>${escape(ip)}</option>`).join("")}</select></label>`)}</article>`,
      ),
    );
  });
  app.post("/admin/settings/network", async (req, reply) => {
    const reason = adminReason(req);
    const bindIP = String((req.body as any).bindIP ?? "");
    const choices = (process.env.API_NETWORK_CHOICES ?? process.env.API_BIND_IP ?? "127.0.0.1").split(",");
    if (!choices.includes(bindIP)) throw new DomainError(422, "Choose a current Raspberry Pi address");
    await db.transaction(async (tx) => {
      await tx.query(
        "INSERT INTO app_settings(key,value) VALUES('preferred_bind_ip',$1::jsonb) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value,updated_at=now()",
        [JSON.stringify(bindIP)],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','network_bind',$2,$3)",
        [randomUUID(), bindIP, reason],
      );
    });
    return bearer(req) ? { preferredBindIP: bindIP, requiresDeploy: true } : reply.redirect("/admin/settings");
  });
  app.post("/admin/settings/scraping", async (req, reply) => {
    const reason = adminReason(req);
    const enabled = z.enum(["true", "false"]).parse(String((req.body as any).enabled)) === "true";
    await db.transaction(async (tx) => {
      await tx.query(
        "UPDATE app_settings SET value=$1::jsonb,updated_at=now() WHERE key='scraping_enabled'",
        [JSON.stringify(enabled)],
      );
      await tx.query(
        "INSERT INTO audit_log(id,actor,action,target,reason) VALUES($1,'admin','scraping_enabled','scraping',$2)",
        [randomUUID(), reason],
      );
    });
    return bearer(req) ? { enabled } : reply.redirect("/admin/settings");
  });
  app.get("/admin/operations", async (_req, reply) => {
    const jobs = (
      await db.query(
        "SELECT kind,status,count(*) FROM jobs GROUP BY kind,status",
      )
    ).rows;
    const notifications = (
      await db.query(
        "SELECT status,count(*) FROM notification_deliveries GROUP BY status",
      )
    ).rows;
    const candidates = (
      await db.query("SELECT kind,count(*) FROM fact_candidates GROUP BY kind")
    ).rows;
    return reply
      .type("text/html")
      .send(
        html(
          "采集、发布与通知",
          `<article><h2>任务</h2><pre>${escape(JSON.stringify(jobs, null, 2))}</pre><h2>通知</h2><pre>${escape(JSON.stringify(notifications, null, 2))}</pre><h2>候选</h2><pre>${escape(JSON.stringify(candidates, null, 2))}</pre></article>`,
        ),
      );
  });
  app.get("/admin/reports", async (_req, reply) => {
    const rows = (
      await db.query("SELECT * FROM reports ORDER BY created_at DESC LIMIT 100")
    ).rows;
    return reply
      .type("text/html")
      .send(
        html(
          "用户纠错",
          rows
            .map(
              (r) =>
                `<article><p>${escape(r.event_id)}</p><p>${escape(r.body)}</p></article>`,
            )
            .join(""),
        ),
      );
  });
  app.post("/admin/pairings", async (req) => {
    const body = z
      .object({ role: z.enum(["owner", "receiver"]).default("receiver") })
      .parse(req.body ?? {});
    const token = randomBytes(32).toString("base64url");
    const challenge = randomBytes(32).toString("base64url");
    const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();
    await db.query(
      "INSERT INTO jobs(id,kind,payload,dedupe_key,status,max_attempts) VALUES($1,'pairing',$2,$3,'queued',1)",
      [
        randomUUID(),
        JSON.stringify({
          challengeHash: digest(challenge),
          role: body.role,
          expires: expiresAt,
        }),
        digest(token),
      ],
    );
    return { token, challenge, expiresAt, role: body.role };
  });
  app.get("/admin/contract", async () => z.toJSONSchema(bundleSchema));
  return app;
}
