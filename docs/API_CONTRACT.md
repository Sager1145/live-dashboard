# API 契约

运行时权威定义为 `server/src/contracts.ts`，`schema/live-dashboard.schema.json` 由 Zod 导出。Swift 对应 `ios/Sources/LiveDashboardKit/Domain/Models/`。旧研究 fixtures 与原始 schema 不是公共 API 数据。

`LiveEventBundle` 保留已有 Swift v1 字段，并增加 `revision`、`editions`、`streamOffers`、`products`、`goodsSessions`、`amount`、`sourceHealth`、图片 `displayPolicy`。所有服务端发布记录都有稳定 ID。缺失精确时间用 `null`；`localDate` 可为 `null`，原文与精度由 `rawDate`、`precision` 保留。金额是 `amount: {minorUnits: integer, currency: ISO4217}`，兼容 `priceJPY` 但不把升级差额与普通票价混算。

范围只接受 `{kind:"performances",performanceIDs:[...]}` 或 `{kind:"unconfirmed"}`。公演、版本、站点共通规则审核时物化为当时确认的场次集合。没有范围不能产生行动按钮或官方提醒，新增场次不自动继承。

`TicketRound` 与 `GoodsCampaign` 各增加 `links: OfficialLink[]`（默认 `[]`），`OfficialLink` 为 `{label: string, url: string}`，用于呈现官方页面上除主要 `applyURL`／`url` 外的其它具名链接。`LiveEventBundle` 增加 `sourceText: string | null`（可选，默认缺省即 `null`），是官方页面的纯文本渲染，其中的链接以 `label（url）` 形式写入正文，长度上限 80000 字符；供无法解析结构化字段时的兜底展示与全文检索使用。

| 方法／路径 | 返回或请求 |
|---|---|
| `GET /v1/catalog/bootstrap` | `{schemaVersion:1,cursor,events:[Bundle]}`，目录锁保证同一提交水位 |
| `GET /v1/catalog/changes?cursor=&limit=` | `{cursor,hasMore,changes:[{sequence,eventID,revision,kind,bundle?,replacementID?}]}` |
| `GET /v1/events` | 筛选 `franchise,group,type,from,to`，分页 `after,limit`；`{events,nextCursor}`，每项含 `matchingPerformanceIDs` |
| `GET /v1/events/:id` | 完整 Bundle；支持 ETag / If-None-Match / 304 |
| `GET /v1/events/:id/changes` | `{changes:[{revision,reason,publishedAt}]}` |
| `GET /v1/media/:id` | 媒体元数据，`link_only` 不产生图片代理或重新托管 |
| `GET /v1/evidence/:id` | 当前版本证据与最多 500 字符短文，原始 HTML 不公开 |
| `POST /v1/installations` | `{id,credential}`；凭证仅返回一次，服务端保存 SHA-256 |
| `PUT /v1/installations/:id/push-token` | `{token,environment:"sandbox"或"production"}` |
| `PUT /v1/installations/:id/subscriptions` | `{subscriptions:[{eventID,performanceIDs,changesEnabled}]}`，替换此安装订阅 |
| `PUT /v1/installations/:id/reminders` | `{reminders:[{eventID,performanceID,recordID,field,leadSeconds,enabled}]}`；field 为 `applyEndAt` 或 `paymentDeadlineAt` |
| `DELETE /v1/installations/:id` | 删除安装、订阅、提醒和投递记录 |
| `POST /v1/reports` | `{eventID?,body}`，body 10–3000 字符 |

安装子路由必须使用 `Authorization: Bearer <credential>`；APNs token 不作为凭证。管理 API 使用独立 `ADMIN_TOKEN`，浏览器表单另有 CSRF token，返回 `Cache-Control:no-store` 和 CSP。

游标是十进制字符串，不转换成 JavaScript/Swift 浮点数。日志保留水位之后的过期游标返回 HTTP 410；客户端重新 bootstrap，只重建公共缓存。应用所有增量和写入缓存成功之后才能提交游标。删除／重映射显式下发，不能通过一次缺失推断删除。

发布前检查引用、显式场次集合、日期区间、关键字段证据、快照存在、来源 URL 和原文引用。审核基础版本不匹配返回 409；业务 hash 未变不发布新版本、不重复入 Outbox。通知投递使用语义截止版本，普通标题变化不会重复发送同一截止提醒。

## 媒体与候选维护补充

- `GET /v1/media/:id/content`：仅返回该公演当前已发布 `version` 和 `contentHash` 对应、且 `displayPolicy=permitted_cache` 的二进制文件；支持 ETag。缓存中有更新但尚未审核的版本不公开。
- `GET /admin/media/:id/versions/:version`：管理员核对特定私有媒体版本，PDF 按附件提供。
- `POST /admin/reviews/:id/edit`：保存经过契约验证的候选，同时清除已核验标记。事件 ID 不可在此接口悄悄替换。
- `POST /admin/sources/:id/policy`、`POST /admin/documents/:id/enabled`：带审核原因的来源策略与文档启停。
- `PUT /v1/installations/:id/reminders`：全量替换安装提醒；现有逻辑键保留 ID。启用的提醒必须引用已确认、明确适用该场次且有目标期限的受付。

目录增量序列是十进制字符串，避免跨端整数范围损失。增量即使没有公演 revision 变化，也返回实时 `sourceHealth` 映射；来源故障不会删除已确认字段。
