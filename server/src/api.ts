import { blobStoreFromEnv } from "./storage/index.js";
import Fastify, { type FastifyRequest } from "fastify";
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { z, ZodError } from "zod";
import type { DB } from "./db.js";
import { reconcileInstallationNotifications } from "./notification-worker.js";
import {
  bundleSchema,
  parseBundle,
  DomainError,
  type Bundle,
} from "./contracts.js";
import { createReview, publishReview, withdrawEvent } from "./publisher.js";

const digest = (s: string) => createHash("sha256").update(s).digest("hex");
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
  `<!doctype html><html lang="zh-Hans"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)} · Live Dashboard</title><style>body{font:16px system-ui;margin:40px auto;padding:0 24px;max-width:1200px;color:#172b35;background:#f5f7f8}a{color:#146276}nav{display:flex;gap:24px;margin-bottom:32px}table{border-collapse:collapse;width:100%;background:white}td,th{padding:12px;text-align:left;border-bottom:1px solid #ddd;vertical-align:top}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}textarea{width:100%;min-height:300px}button{padding:10px 20px;margin:8px;background:#146276;color:white;border:0;border-radius:8px}input{padding:10px}article{background:white;border-radius:12px;padding:24px;margin:16px 0}.columns{display:grid;grid-template-columns:1fr 1fr;gap:20px}.status{color:#536775}</style><nav><a href="/admin">审核</a><a href="/admin/sources">来源健康</a><a href="/admin/events">发布版本</a><a href="/admin/operations">任务与通知</a><a href="/admin/reports">纠错</a></nav><h1>${escape(title)}</h1>${body}</html>`;
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
  options: { adminToken: string; logger?: boolean },
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
  app.put("/v1/installations/:id/push-token", async (req) => {
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
  app.put("/v1/installations/:id/subscriptions", async (req) => {
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
  app.put("/v1/installations/:id/reminders", async (req) => {
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
          `${rows.map((r) => `<article><h2>${escape(r.origin)}</h2><p>${escape(r.health)} · 最近成功 ${escape(r.last_success_at)}</p><pre>${escape(JSON.stringify(r.policy, null, 2))}</pre>${form(`/admin/sources/${r.id}/pause`, "暂停来源")}${form(`/admin/sources/${r.id}/policy`, "保存已审核来源策略", `<textarea name="policy" required>${escape(JSON.stringify(r.policy, null, 2))}</textarea>`)}</article>`).join("")}<table>${docs.map((d) => `<tr><td>${escape(d.fetch_url)}</td><td>${escape(d.health)}</td><td>${d.enabled ? "已启用" : "待审"}${form(`/admin/documents/${d.id}/enabled`, d.enabled ? "停用文档" : "启用文档", `<input type="hidden" name="enabled" value="${!d.enabled}">`)}</td></tr>`).join("")}</table>`,
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
  app.get("/admin/contract", async () => z.toJSONSchema(bundleSchema));
  return app;
}
