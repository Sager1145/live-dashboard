# Live Dashboard：完整实现计划

**版本：1.0 · 规划日期：2026-09-22 · 文档语言：简体中文**

目标：实现一个优先使用 Apple 原生 UI 的 iOS 公演信息 Dashboard，第一阶段只接入 BanG Dream! 与 Love Live!，完成官方来源发现、增量抓取、结构化提取、字段核验、审核发布、卡片呈现、场次切换、更新追踪与提醒。

本文件是交付给开发者／开发 Agent 的实现规格，不是已经完成的 App、运行中的爬虫或自动化任务。附带 sources 配置默认禁用抓取，直到来源规则审查完成；示例接口、目录和命令属于待实现契约。参数、刷新周期和性能数字均为建议初值／验收目标，不是实测结果。

## 0. 已知输入与未完成的验证

已有 `live_dashboard_20_sources_and_ui.json`，包含 20 个公演候选、52 个不同的来源 URL。该文件声明 `not_production_data: true`，只能作为来源种子和回归案例，不能将其中的研究描述、建议分组或日期示例自动升级为官方事实。

本次重新读取了该文件全部内容，并读取了 Bushiroad Live 商品列表、School idol STORE 首页和 e+ 的 13th☆LIVE 页面。BanG Dream! 部分详情在本研究工具中返回 404，Love Live! 部分详情返回 403；这只是本次访问结果，不足以证明站点真实撤页、官方未发布资料或部署后的抓取必定失败。两站的 robots 内容本次未能可靠取得，因此不能声称已获抓取授权或所有页面均可用。

实施开始时必须完成：来源与条款核验、实际部署环境的访问验证、页面快照采集、具体 DOM 选择器验证、20 个候选的身份与场次核验、图片展示／缓存使用方式审核。

**不得用搜索摘要替代生产抓取；不得把上一轮回答本身作为事实来源。**

---

## 1. 产品范围与首版完成定义

### 1.1 首版必须实现

| 编号 | 功能 | 完成条件 |
|---|---|---|
| F01 | 公演卡片首页 | 按公演展示，可筛选企划、团体、活动类型、日期、关注状态；同一公演不因多个 URL 重复出现。 |
| F02 | 详情标题与场次选择 | 顶部完整官方名称；支持版本、站点、日期、Day、昼夜场；四个分区共享一个选择状态。 |
| F03 | 概要／票价 | 显示适用场次的日期、开场／开演、场馆、出演、票种、税费／资格说明。 |
| F04 | 售票 | 每轮受付独立，区分现场、配信、官方转售；显示资格、申请／结果／付款期限与官方入口。 |
| F05 | 座位 | 区分本公演图、场馆通用图、站立区域说明；完整图片放大；无图时不虚构布局。 |
| F06 | 周边 | 支持事前／会期／事后批次；通贩、场贩、线上预约会场领取；商品表及现场说明原图。 |
| F07 | 卡片设置 | 全局默认与公演覆盖；显示、排序、置顶、密度、字段和提醒均可设置。 |
| F08 | 我的公演 | 关注、选定场次、手动申请／付款状态、个人提醒；用户状态与公共数据隔离。 |
| F09 | 数据可信度 | 每个关键字段有来源；区分未获取、解析失败、待核验、官方待公布、不适用。 |
| F10 | 抓取与发布 | 可重复运行、有快照、有差分、有审核、有回滚；不会用抓取失败覆盖已确认数据。 |
| F11 | 离线与更新 | 缓存详情可读，手动刷新自己的 API；显示资料核对时间和更新历史。 |
| F12 | 提醒 | 官方变更及可变截止提醒走服务端；个人静态提醒支持本地通知；支持深链和关闭。 |
| F13 | 运维工具 | 来源健康、解析失败、冲突审核、来源暂停、版本回放与回滚都有操作入口。 |

### 1.2 首版不做

不实现抢票、代登录、代支付、读取用户票务账号、自动查看中签结果、非官方库存预测、演唱会视频下载、社交论坛、二手交易、粉丝自绘座位图自动冒充官方图。

首版不要求用户创建业务账号。iCloud 跨设备同步、Widget、日历导出、更多企划属于后续扩展；公共模型与 Repository 从首版即保留扩展接口，但不能把可选扩展当成核心功能完成的前提。

### 1.3 语言与日期原则

界面默认跟随系统，至少准备中文、日文、英文的 String Catalog。公演名、票种名、受付名默认保留日文原文；可展示人工审核的译名。日期默认以会场所在地时区显示，允许额外显示设备本地时间。不能根据手机时区改写官方日期；不能把自动翻译结果覆盖官方名称。

---

## 2. 总体架构与技术决定

```text
官方列表／公演页／公告／授权票务页／官方商店／场馆资料
    ↓ 受控发现与抓取
Scheduler → PostgreSQL Jobs → Fetch Worker
    ↓
Source Snapshot → Adapter → Candidate Facts → Validator
    ↓                                      ↓
Auto-approve (有限白名单)              Review Console
    └──────────────────┬───────────────────┘
                       ↓
             Publisher（事务发布＋Outbox）
                       ↓
       PostgreSQL 公共目录／不可变公演版本／媒体元数据
                       ↓
              API + Cache + APNs Worker
                       ↓
        SwiftUI iOS App → 本地缓存／用户独立存储
```

### 2.1 技术栈

| 层 | 本计划选择 | 边界 |
|---|---|---|
| iOS | iOS 18+、Swift 6 language mode、SwiftUI、Observation | Xcode 使用开发时已验证可发布的稳定版本；CI 锁定工具链。 |
| 原生持久化 | SwiftData 用户存储；公共目录采用版本化 Codable 文件＋轻量本地索引 | 避免把所有公共公演及图片同步进私人 iCloud。 |
| 网络 | URLSession、async/await、actor 隔离 | UI 主线程不执行 HTML 解析、图片解码或大量 JSON 变换。 |
| 后端 | Node.js 24 LTS、TypeScript、Fastify | Node 官方在本次核验将 24 列为 LTS；不要沿用已 EOL 的 Node 18。[R01] |
| 静态解析 | 统一 HTTP Fetcher＋Cheerio | Fetcher 自己负责网络策略，Adapter 只解析已取得的快照。[R02] |
| 动态页面 | Playwright Chromium，按来源启用 | 只用于正常公开页面的渲染与已批准网络请求，不绕过访问限制。[R03] |
| 数据库 | PostgreSQL 18；SQL migrations | 开发、CI、生产锁定同一受支持大版本并管理安全更新。 |
| 任务队列 | PostgreSQL job 表＋lease／fencing token | 首版不强制引入 Redis、Kafka、微服务；队列表可使用 SKIP LOCKED。[R04] |
| 媒体与快照 | 可替换 BlobStore 接口 | 本地开发用磁盘；生产用私有对象存储。未经审核的原始 HTML 不公开。 |
| 管理后台 | Fastify 服务端渲染页面＋少量前端交互 | 重点是差分、证据和发布，不另外搭复杂 CMS。 |
| 部署 | 一个代码仓库，多进程／容器角色 | API、scheduler、fetch worker、browser worker、notification worker 分别限制资源。 |

iOS 不承担持续抓取。Apple 的后台执行由系统限制与调度，不应设计为手机每隔固定分钟可靠运行抓取器。[R05]

### 2.2 三种数据严格分开

1. **原始来源数据**：HTML／允许保存的文件、响应元数据、正文片段，只能作为证据，不直接展示为 App 页面。
2. **已发布公共数据**：规范化公演版本与已核验事实，只由 Publisher 写入。
3. **用户私有数据**：关注、卡片偏好、申请记录、个人提醒，与公共数据清理／更新完全隔离。

---

## 3. 公演身份、范围与数据库模型

### 3.1 公演结构

```text
PresentationGroup（可选，仅用于首页归组）
  └── LiveEvent（官方独立公演或巡演）
       ├── Edition（原场／再景／追加版本，可选）
       │    └── LiveStop（城市站点，可选）
       │         └── Performance（实际的一场演出）
       └── 无版本或无巡演时，Performance 直接挂到事件
```

不是所有公演都强行生成四层。单日单场只需要 Event＋Performance。共演团体是多对多关系，不是复制 Event。首页归组不等于数据库合并身份；MyGO 原场与神户版本的关系未确认前，宁可保留独立 Event 并建立展示组。

ID 使用服务器生成的稳定 UUID；不可由标题、日期、Day 数字或数组下标直接生成。延期后保留 Performance ID；仅更新时刻、状态和历史。确认为取消后重新举办的独立公演，需要人工建立 replaced_by／related_to，而非无条件复用。

### 3.2 核心表

| 表组 | 建议表 | 关键职责 |
|---|---|---|
| 身份 | events, editions, stops, performances, presentation_groups, entity_aliases | 公演层级、别名、历史 URL、人工合并／拆分映射。 |
| 团体／出演 | franchises, artists, event_artists, performance_cast | 按实际场次保存现场、嘉宾、暖场、影像出演等角色。 |
| 场馆 | venues, venue_aliases | 历史名称、地址、时区和通用图；公演图另行保存。 |
| 票务 | ticket_tiers, ticket_rounds, ticket_offers, ticket_eligibilities | 一轮受付可关联多票种多场次；资格不混入价格。 |
| 配信 | stream_offers, stream_access_windows | 购买期限、直播、回放、地区限制分开。 |
| 物贩 | goods_campaigns, products, product_variants, campaign_products, goods_sessions, shipment_estimates | 批次、单品规格、场贩时段、领取／发货独立。 |
| 公告 | notices, notice_targets | 取消、延期、退票、入场和新增信息。 |
| 范围 | applicability_sets, applicability_members | 具体适用哪些 Event／Edition／Stop／Performance，并保留范围证据。 |
| 来源 | source_origins, source_documents, document_entity_links, source_fetches, source_snapshots | 一个文档可支持多个公演，一个公演可以有多个文档。 |
| 事实 | fact_candidates, fact_evidence, accepted_fact_versions, review_cases, editorial_overrides | 候选→审核→接受，保留冲突和人工覆盖。 |
| 发布 | event_revisions, catalog_changes, outbox_events | 不可变公演快照、增量目录和可靠事件投递。 |
| 任务 | jobs, origin_rate_limits | 持久队列、限流、重试和租约。 |
| 提醒 | installations, subscriptions, reminders, notification_deliveries | 安装级鉴权、订阅、服务器动态提醒、幂等投递。 |
| 媒体 | media_assets, media_versions, media_usages | 图片版本、原始用途、权利策略和适用范围。 |

首版允许将复杂资格说明作为带类型的 JSONB＋原文保存；但身份、场次、票务关联、来源、版本和任务不能只塞进无约束的大 JSON。

### 3.3 范围匹配规则

每条票价、受付、商品批次、座位图和公告都必须有 `applicabilityID`。未知范围保存为 `unresolved`，不是空数组代表“全部”。

`all_event` 只在来源明确说明“全日共通”等情况下成立。默认把当时已知场次物化为成员集合，并记录 scopeRevision；新增追加场不自动继承旧资料，除非官方明确说明共通范围包括该场。同理，一个巡演站的规则不能传播到其他城市。

每张详情卡的可见性为：

```text
所属已发布公演版本
AND 范围匹配当前选择
AND 信息已核验或是明确标识的待确认资料
AND 用户允许显示
```

未知范围的资料放到“适用场次待确认”区域，不进入主行动按钮、最低价和自动提醒。

### 3.4 时间与金额

时间保存：原始文本、ISO 本地日期、当地时间、IANA 时区、可计算时的 UTC instant、precision、来源上下文。precision 至少支持 minute／date／month／range／unknown。未公布开演时间时不能创建 00:00 作为事实。

明确拆分：doorsAt、startsAt、applicationOpensAt、applicationClosesAt、resultsAt、paymentDueAt、goodsSaleOpensAt、goodsSaleClosesAt、pickupWindow、shippingEstimate、streamSalesClosesAt、archiveAvailableUntil。

金额保存：整数 minor units＋币种＋税费说明＋价格类型＋资格。JPY 15000 保存 15000，不能统一乘以 100；CAD／USD 则按对应 minor unit 处理。升级差额、通票、U20、配信票、商品消费门槛不得混算为普通现场票最低价。首版不做自动汇率换算。

### 3.5 事实状态与时效拆开

业务知识状态：`confirmed | officially_tba | not_collected | needs_review | not_applicable`。

来源健康状态：`healthy | stale | fetch_failed | blocked | parse_failed`。

不要因抓取失败把一个 confirmed 值改为 null。可以显示“已确认的旧值＋核对时间＋来源暂不可用”。状态按字段／区块计算，不能因为商品页今天成功抓取，就让未核对的票务显示“今日已核验”。

另存 `sourcePublishedAt`、`sourceModifiedAt`、`observedAt`、`lastSuccessfulFetchAt`、`fieldVerifiedAt`、`publishedAt`。最近抓到的旧文章没有自动覆盖新公告的权限。

---

## 4. 来源登记与自动发现

### 4.1 第一批发现入口

以下是待上线核验的来源注册种子，不代表全部已通过 robots／条款／可访问性审核。

```text
https://bang-dream.com/events/
https://bushiroad-store.com/blogs/live
https://www.lovelive-anime.jp/news/
https://www.lovelive-anime.jp/uranohoshi/live.php
https://www.lovelive-anime.jp/nijigasaki/live.php
https://www.lovelive-anime.jp/yuigaoka/live/
https://www.lovelive-anime.jp/hasunosora/live-event/
https://www.lovelive-anime.jp/lovehigh/live/
https://lovelive.fannect.jp/
https://lovelive-store.bnfw.jp/
```

跨系列 special 详情由主站新闻、官方导航及现有种子发现，不编造未验证的 special 列表地址。其它官方专题域名、售票商、出演者与场馆域名按明确关联逐项登记；不是“只要在官方页中出现，就无限制爬完整个外部域名”。

Bushiroad 当前商品列表确实按公演和 Day 提供不同通贩文章，并包含其它企划／艺人，因此需要内容归属筛选。[R06] School idol STORE 是本次读取到的现行商品入口之一，但旧门户和迁移链接仍需要独立验证。[R07]

### 4.2 来源注册对象

每个 origin 保存 host、allowedPaths、允许抓取的方法与内容类型、robots 检查结果、条款审查记录、最大频率、日预算、内容展示策略、ownerVerification、访问模式和停用开关。

每个 document 保存 exact fetchURL、用于去重的 identityURL、官方实体键、adapterID、预期内容类型、已知实体关联、发现来源、首次发现时间、最后成功快照、nextFetchAt。

**Fetch URL、身份 URL、用户跳转 URL 分开。**签名 URL、购票参数和商品 variant 参数不得为了“去重”破坏原始可用链接。规范化只移除经该来源验证确实不影响身份的追踪参数；未知参数默认保留。

### 4.3 发现算法

按批准的种子页抓取主内容链接 → 识别活动／公演／票务／物贩候选 → URL 去重 → 判断现有别名与官方 key → 新域名或未知模板进入审核 → 只为批准候选创建抓取任务。

列表首次回填跟随真实分页链接；支持 rel=next、分页导航、获准 sitemap。设置最大深度 3、单来源单次发现上限 50；这些为启动保护值，按来源修改。不能猜测隐藏编号批量枚举路径，不能从页面年份推测不存在的 URL。

更新时：已知页面可按 ETag／Last-Modified 验证；列表没有新项目可以停止向后翻页，但每周做一次有上限的重新扫描，避免置顶／重排导致漏项。所有重复任务按 documentID 与调度窗口去重。

关键词只用于候选分类，不能作为事实发布依据。否定词如 発売、Blu-ray、CD、映画、配信、通販 用于提示内容类型，不简单全部排除，因为它们可能包含真实先行资格或物贩信息。

### 4.4 URL 与身份规则

Love Live! 的 `p`、`_id` 等语义参数必须保存；不同路径的相同参数值也未必是同一实体。BanG Dream! 保留详情 slug 和专题路径；总页与 Day 页建立关系而非重复建公演。

301／308 保存 redirect alias 并核实实体；跳转到首页、维护页、店铺迁移说明不能当作等价公演。rel=canonical 是线索，不是跨域可信授权。e+ 的某些入口是艺人列表而非唯一公演，必须按内部场次区块二次识别。

---

## 5. 完整抓取流水线

### 5.1 执行状态机

```text
discovered → policy_pending → eligible → scheduled → fetching
                                                   ├→ unchanged
                                                   ├→ retry_wait
                                                   ├→ blocked
                                                   └→ snapshotted → parsed
                                                                    ├→ needs_review
                                                                    ├→ rejected
                                                                    └→ validated → published
```

任务状态与数据发布状态是不同状态机。一次 fetch_failed 只修改任务／来源健康，不撤回线上公演。

### 5.2 Fetcher 的硬性要求

所有 HTML、JSON、图片和 PDF 请求都经过统一受控网络层：HTTPS、精确域名／路径准入、方法白名单、DNS 与最终连接地址验证、每次重定向重新校验、TLS 校验、超时、压缩后解码上限、总字节上限、内容类型与 magic bytes 核验。

防 SSRF 不能仅写 `url.startsWith('https')`：禁止 loopback、私网、link-local、云元数据 IP、用户信息字段和非批准端口；处理 IPv6、DNS rebinding；Playwright 子资源也受相同 egress 约束。优先使用网络层出站防火墙／代理实现不可绕过的约束。[R08]

初值：HTML 请求总超时 20 秒，最大解压后 5 MiB；PDF／图片按专门队列限制 25 MiB 并验证实际格式；最多 3 次普通重试。所有数字可配置，不是对所有站点一刀切的保证。

原始请求只做公开读取，不自动 POST 申请、登录或加入购物车。robots 为路径准入信号，不是内容再利用授权；还需核验站点条款与素材使用方式。[R09][R10]

### 5.3 响应处理

| 情况 | 必须行为 |
|---|---|
| 200 正常正文 | 保存快照与响应头；判断正文／关键区块是否变化。 |
| 200 登录、验证码、维护、空壳 | 标记 blocked／unexpected_template；不进入正常解析。 |
| 304 | 关联已有快照并更新成功验证时间；不得把空响应当成清空数据。 |
| 301／302／307／308 | 验证每一跳；仅批准目标可以继续；记录跳转链。 |
| 401／403／验证码 | 停止自动重试和浏览器“绕过”；来源进入人工检查。 |
| 404／410 | 记录缺失并有限期复核；不得推断取消或删除已发布公演。 |
| 429 | 尊重 Retry-After，指数退避并降低来源预算。 |
| 5xx／网络超时 | 有限重试＋随机抖动；保留 last-known-good。 |
| robots／条款未知或无法核验 | 配置保持 pending，部署者完成审查后才能开放正常抓取。 |

采用条件请求遵循 HTTP 的 ETag／Last-Modified 语义；服务器未提供验证器时不能伪造其值。[R11]

### 5.4 什么时候使用浏览器

先保存原始 HTML；只有确认页面正常可公开访问、关键内容由 JavaScript 动态载入且该来源已批准时，再用 Playwright。一个干净浏览器 context 对应一次任务，完成即关闭，不携带个人登录状态。

等待具体内容容器或批准数据响应，不无限等待 networkidle。允许只拦截广告、视频、无关追踪等已验证不会影响内容的资源。禁止捕获用户 Cookie／令牌、禁止把浏览器访问成功解释成抓取或内容再利用许可。

若页面公开请求提供稳定 JSON，可以经审核后建立该公开接口适配器，并保留 HTML 对照；不能根据隐藏 token／私有鉴权接口构建生产依赖。Playwright 提供网络监测和请求控制能力，适合这一限定用途。[R03]

### 5.5 快照内容

保存 snapshotID、sourceDocumentID、fetchURL／finalURL、HTTP 状态、必要响应头、fetch 时间、源站发布时间（有则保存）、原始字节内容 hash、标准化正文 hash、adapterVersion、selectorProfileVersion、locale 和存储对象 key。

Cookie、Authorization、session 参数等不得写入日志或可共享 fixture。正文 hash 只用于判断是否需要重新解析，不能代替媒体更新检测。即使 HTML 未变，已登记的图片仍需按媒体策略单独复核。

### 5.6 刷新与预算

| 文档类别 | 建议目标间隔 |
|---|---|
| 活动／新闻／商品发现列表 | 6 小时 |
| 有效公演详情与票务页 | 2 小时 |
| 已确认受付或开演临近 72 小时 | 1 小时；来源允许且预算充足时才提高 |
| 远期且无进行中动作的详情 | 24 小时 |
| 结束但仍有通贩／配信／发货事项 | 6～24 小时，按事项调整 |
| 无待办的历史公演 | 7 天；长期归档可暂停 |

默认单 origin 1 个文档并发、文档请求最小间隔 10 秒、500 次文档尝试／日；媒体和浏览器子请求另有更严格可配置字节／请求预算，并计入 origin 总预算。任务积压时预算和站点规则优先于目标周期。文档复用按 URL 去重，不能因 1 万用户关注而重复抓 1 万次。

用户下拉刷新只刷新 App 自己的 API，不直接触发源站请求；“报告资料过旧”可提交带冷却的后台审核／刷新建议，不提供任意 URL 抓取接口。

官网数据本身也可能延迟；e+ 页面明确提示状态不一定实时反映。因此 App 文案应是“最近核对／按公告推算”，而不是“保证实时库存”。[R12]

### 5.7 Jobs、lease 和崩溃恢复

jobs 保存 jobID、kind、documentID、uniqueKey、priority、dueAt、attempts、maxAttempts、leaseUntil、leaseToken、workerID、lastError。

短事务使用 SELECT … FOR UPDATE SKIP LOCKED 领取任务并生成 fencing token；提交后才访问网络，不能持有数据库事务等待网页。耗时任务心跳续租，写结果时核对 token。租约过期可重领，但旧 worker 结果必须被拒绝或仅作为不发布的审计记录。[R04]

采用至少一次执行＋幂等写入，而非宣称 exactly-once。解析幂等键至少包括 snapshotID、adapterVersion、configurationVersion；发布检查 baseRevision，旧候选无法覆盖较新线上版本。

---

## 6. 各类页面的提取实现

### 6.1 Adapter 目录与责任

```text
adapters/
  bangdream/EventIndexAdapter.ts
  bangdream/EventDetailAdapter.ts
  bangdream/SpecialTourAdapter.ts
  lovelive/BranchIndexAdapter.ts
  lovelive/LiveDetailAdapter.ts
  lovelive/LegacyLiveAdapter.ts
  lovelive/NewsAdapter.ts
  tickets/EplusAdapter.ts
  goods/BushiroadLiveArticleAdapter.ts
  goods/BushiroadProductAdapter.ts
  goods/SchoolIdolStoreAdapter.ts
  reference/VenueReferenceAdapter.ts
  reference/OfficialReleaseAdapter.ts
```

按模板族复用，不给每场公演手写一套，也不使用一个“万能全页正则”。新模板进入人工检查；解析器不能在找不到主内容时自动降级到扫描整个 body。

### 6.2 Adapter 契约

以下为待实现 TypeScript 接口；类型引用的基础模型需在 contracts 包定义，非完整可执行爬虫。

```ts
interface SourceAdapter {
  readonly id: string;
  readonly version: string;

  // 仅识别模板；未知模板必须显式拒绝，不猜测。
  matches(snapshot: SourceSnapshot): MatchDecision;
  discover(snapshot: SourceSnapshot): readonly CandidateLink[];
  extract(snapshot: SourceSnapshot, context: ParseContext): ParseResult;
}

interface ParseResult {
  candidates: readonly FactCandidate[];
  media: readonly MediaCandidate[];
  links: readonly CandidateLink[];
  sections: readonly SectionCoverage[];
  issues: readonly ParseIssue[];
}

interface FactCandidate {
  entityRef: CandidateEntityRef;
  field: FactField;
  value: unknown; // 发布前必须通过该 FactField 对应 JSON Schema。
  applicability: ApplicabilityCandidate;
  sourceSnapshotID: string;
  evidence: {
    sectionPath: readonly string[];
    locator: string;
    rawText: string;
    nearbyHeading?: string;
    sourceLanguage: string;
  };
  extractionMethod: "dom" | "structured_data" | "pdf_text" | "manual";
  parserVersion: string;
}
```

Adapter 只输出候选和证据；不访问网络、不修改正式库、不推送通知、不决定正式实体身份。正式实体 ID 由身份解析与发布流程分配，所有网络读取由 Fetcher 统一调度。

### 6.3 DOM 预处理

先按模板定位 article／main／公演容器，再排除导航、页脚、其它活动推荐、全站配送公告和图标说明。保留标题层级、段落顺序、table 行列关系、dl 的 dt/dd、折叠区块和锚点。

对 table 展开 rowspan／colspan，但保留原单元格坐标，以便“某城市两天共通的场馆”只影响相应行。只为搜索匹配建立 NFKC、全角数字转换等标准化副本；官方原文不能被破坏性覆盖。

Cheerio 支持从字节加载并处理编码识别；优先保存原始字节，再解析，而不是默认所有网页均为 UTF-8。[R02]

### 6.4 BanG Dream! 提取步骤

1. 从活动列表取得候选详情及官方团体标签。
2. 识别总专题、单日详情、巡演城市导航和相关公告。
3. 对 概要／日程／会場／出演／チケット／グッズ／物販／注意事項 等标题建立 section tree。
4. 每个 Day／城市标题创建候选范围，后续区块继承到下一个同级标题，但不跨出父区块。
5. 从票务子标题提取票种／轮次及平台链接；从 Goods 区块提取批次、店铺链接及媒体。
6. 通过显式链接和已审核映射把总页与 Day 页关联。
7. 扫描数字只能发生在已判定的语义区块内。

13th☆LIVE 应作为第一个完整垂直样本：总页＋三日详情＋e+ 轮次＋按日商品；e+ 当前正文确实按 Day 分段列出多个受付，因此应先分场，再分轮次，而非直接合并所有受付日期。[R12]

### 6.5 Love Live! 提取步骤

1. 为 Aqours／虹咲／Liella!／莲之空／Lovehigh／跨系列分别登记发现路径。
2. 按 URL 路径与 `p`／`_id` 建候选官方键，但仍以正文确认身份。
3. 对新式 live_detail 页面使用统一模板族，对旧式票务／Goods 分页面用独立适配器。
4. 将公演、出演、受付、海外观众、物贩、出展、配信分区独立分类。
5. 新闻／音乐发行页提取“某商品封入券 → 某轮受付 → 指定 Day”的资格关系，不生成虚假的现场日期。
6. 保存影片／影像出演与现场出演的区别；Film Live 不强制标记为纯现场演唱会。
7. 某个官方分支目录暂时不可读取时，不将整个 Love Live! 系列标记为无公演。

### 6.6 票务提取

每个轮次保存：原名、抽选／先着、受付窗口、结果与付款说明、资格、平台、官方公告链接、用户申请入口和适用场次。一个轮次可包含多个 offer；每个 offer 才关联具体票种与价格。

如果入口只有“下一步”按钮、跳转需要当前 session，而没有稳定公开申请 URL：保存可复现的官方落地页＋“在页面选择该轮受付”说明，不伪造隐藏 action URL，也不自动提交表单。

页面底部的通用图标图例不是当前公演要求。必须在该场／该轮范围内看到关联图标或文字，才能标记同行者登记、照片登记等条件。

`announcedWindowState`、`providerObservedState`、`inventoryState` 分开。只知道时间窗口时展示“按公告处于受付期间，库存请在官方确认”；如果平台状态过旧，要显示采样时间，而不是继续承诺可购买。

### 6.7 物贩提取

每个 GoodsCampaign 至少有：官方批次名、purchaseChannel、fulfillmentMethod、phase、销售期间、适用场次、销售链接、规则及媒体。

```text
purchaseChannel: online | venue
fulfillmentMethod: shipping | venue_pickup | immediate_handover
phase: pre_event | event_period | post_event | mixed | unknown
```

购买渠道与履约方式是正交关系；“线上预订＋会场领取”不能被迫归入一种错误类别。

批次与单品分开。ProductVariant 保存颜色／尺寸等规格、价格、库存与限购；商品售罄只作用于对应 variant。首版必须完成批次与商品表，不要求穷举整个商店全部 SKU，不能为了一个公演抓取全站商品。

场贩时段使用 GoodsSession，而非 Performance 时间：可能有前日物贩、不同入口、分时预约和休息时间。发货使用文字／日期区间，不把“6 月以后”转成 6 月 1 日确定发货。受注商品可以覆盖批次默认发货说明。

两家商店若有公开 JSON-LD 或公开商品数据，可以作为候选字段来源，但需核对可见正文与当前批次；本计划不假设 `/products.json` 等接口可用或获准。

### 6.8 日期与数字解析规则

日语日期支持 `YYYY年M月D日`、斜线格式、Day 标签、`開場／開演`、`受付期間`、`～` 范围、`翌`、24:00 和跨年窗口。年份缺失时，只能使用同一公演区块中的明确上下文；不能用抓取当天年份填入。

遇到 24:00，保留官方原文并规范化为次日零点；精度为“仅日期”的截止，不自动改为 23:59。时区只允许来自明确官方说明或已核验场馆地区，香港／台湾等不沿用日本时区。

价格识别必须保留单位与上下文：通常票／优待票／升级差额／商品售价／消费门槛／手续费各自分类。缺少币种或金额含义不明时进入审核。

### 6.9 摘要与可选 AI

首页与卡片摘要优先用确定性模板从已核验字段生成。诸如“下一项截止”“普通票价”“需序列码”的判断来自规则引擎，不是让模型自由总结整页。

大模型可选用于未知段落分类、译文草稿和提取候选，不是首版运行依赖。必须结构化输出、逐字段证据、禁止执行来源文本中的指令、禁止授予任意网络／文件／发布权限。金额、时刻、购票资格、取消／退票等关键事实不凭模型自报置信度自动发布。

---

## 7. 字段校验、审核、差分与发布

### 7.1 分层校验

| 层 | 核验项目 |
|---|---|
| Schema | 字段类型、枚举、ID、金额格式、日期精度、URL 格式。 |
| 范围 | 场次属于该公演，Day 与城市不串用，范围非空且有证据。 |
| 时间 | 申请窗口顺序合理、年份上下文明确；异常值进入审核而非强行修正。 |
| 语义 | 物贩门槛不作票价、回放日不作公演日、全站图例不作入场条件。 |
| 来源 | 关键值有原文／定位／快照；过时源不能凭抓取新而优先。 |
| 差分 | 新增、修改、撤回分别处理；未知字段不是删除指令。 |
| 媒体 | 分类、对应场次、版本、格式、用途、展示权限。 |

首次接入模板必须人工批准。已有模板的后续变更默认仍进入候选区；通过足够快照回归并有严格条件的低风险字段，才进入自动发布白名单。取消／延期、票价、资格、付款／申请截止、座位图用途和实体合并始终需要人工复核或事先建立的专用核验规则；上线初期统一人工复核。

首版允许发布“名称＋已确认日程＋官方来源”，其它分区保持资料状态；不能为了凑满卡片虚构空字段。无法确认公演身份的候选不可发布。

### 7.2 来源冲突不是简单排序

字段负责人按语义指定：主办方负责公演与更正、该轮售票平台负责平台入口和观测状态、商店负责商品与批次、场馆只补充场馆通用信息。发布的新更正公告可以优先于尚未更新的旧详情，但必须保留它明确更正的证据。

不能制定“e+ 总是覆盖官网”或“所有新闻总是覆盖详情”。若 Day1 与 Day2、原场与追加场、商品与公演范围冲突，先纠正关联，再比较值。

### 7.3 审核后台

需要四个核心页面：来源健康、待审核队列、公演差分、来源证据。

审核界面显示旧值／候选值／原文／来源发布时间／抓取时间／适用范围，并支持：接受、拒绝、修改范围、保留两条不同事实、设置人工覆盖、申请重抓、暂停来源。人工编辑必须填理由与证据，保存操作者、时间和覆盖有效期。

若来源不可自动读取，允许管理员上传合法取得的网页／文字／图片并记录来源与采集时间，走相同审核链，不得伪装为自动抓取。不能把人工通道用来绕过站点限制。

原始 HTML 必须作为转义文本或隔离后的受控内容查看；不能在管理站直接执行来源脚本。

### 7.4 缺失与删除

DOM 改版造成列表突然变空：标记 parse_failed。页面不再出现某轮票务：标记该来源此次未见，默认保留历史；有明确撤回公告或审核确认后才 tombstone。全部抓取成功也不保证“没看到＝官方从未公开”。

实体被误合并时要能拆分，重建关联并保留旧 ID 重定向；客户端收到 remap 时迁移关注／偏好，而不是让用户数据丢失。

### 7.5 发布事务

Publisher 是唯一正式写入入口。一次事务：校验 baseRevision → 写 accepted facts／实体关联 → 创建 eventRevision → 更新 currentRevision → 写 catalog change → 写 outbox → 提交。

公演版本中可携带不同来源时点的已确认字段，但必须标明各字段新鲜度；原子发布不意味着所有官网在同一秒核对。跨公演的共通物贩资料变更，应在同一发布批次更新受影响公演或引用同一不可变共通资源版本。

发布版本采用内容 hash 去重；同一候选重复执行不产生第二条提醒。人工回滚不删除历史版本，而是基于旧内容发布一个新 revision，并明确记录回滚原因。

### 7.6 全局增量游标

不能直接把 PostgreSQL sequence 的最大值当作“所有更早事务均已提交”的保证。计划使用 `catalog_clock` 单行锁串行分配 publication sequence；持锁事务同时写入 change log 并提交，使已发布游标具有确定提交顺序。

bootstrap 和 delta 在一致性读取快照中取得 highWatermark。delta 只返回 `(cursor, highWatermark]`，按 sequence＋稳定二级键分页。失效游标返回 410／`requiresBootstrap`。删除、合并、撤回都必须有显式 change 项。

### 7.7 重要更新定义

新增受付、截止修改、时间／会场变更、出演变化、取消／延期／退票、新座位图、新物贩批次／商品表是重要差分。空格、导航、广告、抓取时间刷新和图库 CDN 无内容变化的 URL 更换不产生用户通知。

图片字节变化但内容语义未知时先生成“图片有更新”候选，再核实是否为重要商品表／座位图更新；不能仅依靠感知 hash 判定价格变化。

---

## 8. 图片、座位表与 PDF 处理

### 8.1 媒体模型

`MediaAsset` 保存 identity、用途、来源；`MediaVersion` 保存具体原图 URL、hash、尺寸、格式、字节大小、获取时间、允许缓存方式；`MediaUsage` 绑定公演、批次和适用场次。

用途枚举：key_visual、goods_catalog、onsite_sales_rules、venue_goods_map、event_seating_plan、generic_venue_seating、standing_zone、product_photo、other。

`event_seating_plan` 必须有明确本公演证据；场馆通用图始终显示“仅场馆参考，不代表本场舞台配置”。不引入粉丝图或其它演唱会图自动补齐。

### 8.2 获取和更新

检查 img src、srcset、picture、已确认的懒加载属性及包裹的原图链接，按实际尺寸选择清晰版本。CDN 域名由来源明确引用后审核加入媒体 allowlist；不允许随便下载任何 URL。

同 URL 可能更新内容，定时条件请求；需要防缓存时按 HTTP 协议重新验证，不随意追加随机查询参数。保留 hash 版本，客户端缓存键是 assetID＋version，不只是 URL。

校验格式、大小、像素总数和解码资源；拒绝伪装图片和超大解压炸弹。SVG 如需展示，禁用脚本／外链并在隔离环境转换；原始媒体不在 API 进程内进行不受限解码。

### 8.3 PDF 与图中文字

先获取 PDF 文本层并保留页码；没有可用文本或图形是关键证据时，生成受控页面预览供人工核验。只有唯一信息在图片中时才考虑图中文字识别，且输出仍是候选，不能直接变成截止提醒。

App 使用原生 PDF／图片查看器，可完整缩放；商品长图不能强制裁剪。保留官方原图入口和用途说明，不对关键价格／时间图片进行“美化重绘”。

### 8.4 权利与缓存策略

每个来源／媒体有 `link_only | permitted_remote_display | permitted_cache` 策略及审查依据。未确定权限时默认 link_only；不能以“公开网页”或“App 免费”推断允许重新托管。robots 不提供再利用授权，App Store 也要求符合第三方服务条款与内容权利要求。[R09][R10]

原始 HTML 快照建议仅内部保存 30 天，关键发布证据按获得的许可与维护需要保留；媒体预算／清理保留不可变元数据。保留周期必须可按来源调整，不做无期限全站镜像。

---

## 9. API 契约与缓存

### 9.1 对外接口

| 方法与路径 | 功能 |
|---|---|
| GET /v1/catalog/bootstrap | 一致性初始目录、highWatermark、schemaVersion。 |
| GET /v1/events | 首页摘要筛选；cursor 分页；按 matchedPerformanceIDs 返回筛选命中的场次。 |
| GET /v1/events/{id} | 单项公演完整当前版本，全部场次及其关联资料，不包含大图片字节。 |
| GET /v1/events/{id}/changes | 已发布的重要变更历史。 |
| GET /v1/catalog/changes?cursor=… | 增量 upsert／tombstone／remap。 |
| GET /v1/media/{id} | 已批准媒体元数据、版本与访问方式。 |
| GET /v1/evidence/{id} | 允许公开的来源摘要、短证据片段、官方跳转链接；不暴露私有快照。 |
| POST /v1/installations | 注册匿名安装凭证，不把 APNs token 当身份。 |
| PUT /v1/installations/{id}/push-token | 鉴权更新通知 token 与环境。 |
| PUT /v1/installations/{id}/subscriptions | 完整替换该安装订阅；带客户端版本／幂等键。 |
| PUT /v1/installations/{id}/reminders | 设置官方动态期限提醒规则。 |
| DELETE /v1/installations/{id} | 撤销凭证、订阅、token 与保留范围内的个人服务器记录。 |
| POST /v1/reports | 提交结构化资料问题；限流，不直接发布用户文本。 |

这些是待实现接口，不是现存在线服务。管理接口独立鉴权；不得公开 raw snapshot、任意抓取、Publisher 或数据库写权限。

### 9.2 响应例子

以下 ID、标题和日期为合成测试数据，非真实公演资讯。

```json
{
  "schemaVersion": 1,
  "eventID": "event_fixture_001",
  "contentRevision": 12,
  "publicationSequence": 240,
  "officialTitle": "合成测试公演",
  "performanceOrder": ["perf_day1", "perf_day2"],
  "performances": [
    {
      "id": "perf_day1",
      "localDate": "2027-02-06",
      "timeZone": "Asia/Tokyo",
      "startsAt": {
        "state": "confirmed",
        "value": "2027-02-06T18:00:00+09:00",
        "precision": "minute",
        "evidenceIDs": ["ev_start_1"]
      }
    },
    {
      "id": "perf_day2",
      "localDate": "2027-02-07",
      "timeZone": "Asia/Tokyo",
      "startsAt": {
        "state": "officially_tba",
        "value": null,
        "precision": "unknown",
        "evidenceIDs": ["ev_tba_2"]
      }
    }
  ],
  "ticketRounds": [],
  "goodsCampaigns": [],
  "media": [],
  "sectionCoverage": {
    "tickets": "needs_review",
    "seating": "not_collected",
    "goods": "not_collected"
  }
}
```

真实响应的 schema 必须强制 `performanceOrder` 中每个 ID 均存在，并验证每个 evidenceID 可解析；上例只是合成接口示意，完整集成 fixture 还需要关联证据及全部必填字段。

### 9.3 API 规则

字段枚举可扩展，iOS 未知枚举需降级而非崩溃；关键不兼容修改提高 schemaVersion。Fastify 请求与响应通过内部可信 JSON Schema 校验，不能接受用户上传可执行 schema。[R13]

ETag 根据真实响应表示计算。内容 revision 与来源核对元数据版本分开：304 核对更新可改变“最后验证时间”，但不应产生内容变更或通知。客户端不依靠仅内容版本判断所有时效元数据未变。

API 返回 serverNow 和状态推算依据，关键倒计时使用服务器时间偏差估计。缓存过旧时降级文案，不能靠设备错误时钟显示“保证受付中”。

首页只拿摘要和缩略图，详情一次下载所属公演全部结构化记录；历史长列表、商品 SKU 和媒体可分页补充，但场次相关的基本模型应本地可切换。

---

## 10. 原生 iOS 实现

### 10.1 导航与视图

底部原生 `TabView`：演出／我的／设置。各自持有 `NavigationStack`，避免切底部 Tab 丢失导航。

首页：`.searchable`、筛选 `sheet`、`ScrollView + LazyVStack` 卡片流、`.refreshable`。卡片优先显示标题、下一场／选定场、城市、最相关受付或截止、更新提示；主视觉只占适量空间。

详情：多行标题最上方，接站点／日期选择，再接 `Picker(.segmented)` 的“概要／售票／座位／周边”。单场隐藏日期选择；2～3 场可分段；多站／同日多场使用原生 Menu 或选择 sheet。大字体时分段内容不能挤压，允许改用原生菜单分区选择。

每张卡右上角原生 Menu；复杂编辑进入 Form／List，使用 EditButton、onMove、Toggle 等系统交互。来源、长说明用 sheet／DisclosureGroup；不自绘导航栏和复杂控件，不用 WebView 代替内容界面。SwiftUI 的状态管理以 Observation 连接模型与视图。[R14]

### 10.2 统一选择状态

```swift
struct LiveSelection: Equatable, Codable, Sendable {
    var eventID: String
    var editionID: String?
    var stopID: String?
    var performanceID: String?
}
```

`@MainActor @Observable LiveDetailStore` 是当前页面选择的唯一持有者。四个 Tab 只读取经过 ScopeResolver 计算的结果，不能分别保存自己的 Day。

切换事件：验证目标 ID → 更新选择 → 本地重算当前卡片 → 保留当前 Tab → 必要补充加载。请求响应附带 eventID／revision；用户切换后旧请求不能覆盖新公演。View 的 task 按实体 ID 取消；Repository 还需要响应身份检查。

默认选择：深链指定场次 > 用户曾选场次 > 当前筛选匹配的下一场 > 公演下一场 > 最近历史场。没有可选择场次时停留公演层并显示资料状态，不能虚构 Day1。

### 10.3 卡片目录

| Tab | CardKind |
|---|---|
| 概要 | schedule, venue, cast, ticketPrices, admissionRequirements |
| 售票 | activeRounds, upcomingRounds, eligibility, resultsAndPayment, officialResale, streaming, pastRounds |
| 座位 | eventSeating, genericVenueSeating, standingZones, seatNotes |
| 周边 | onsiteSessions, onlineCampaigns, venuePickup, goodsCatalog, shipping, purchaseRestrictions |

取消／延期等 critical notice 固定属于标题区域，不作为可隐藏普通卡。卡片模型是经过筛选的视图数据，不把官网 HTML 传给 View。

### 10.4 用户设置

键由 `scope + eventID? + cardKind + entityID?` 构成，保存可见性、置顶、排序、密度、字段、提醒类型和提前量。区分“这个具体受付不显示”和“所有历史受付卡默认折叠”。

优先级：具体实体覆盖 > 公演卡片覆盖 > 全局默认 > 内置默认。新增卡片按默认规则加入，不重新排序旧卡；恢复默认只清理对应 scope，不删关注或个人记录。

首版排序保存稳定 card key 列表或 rank，不用数组下标当身份。单机设置无需提前构建复杂 CRDT；未来多设备冲突按设置字段／布局记录解决，不能同步整个公共 Event 对象。

### 10.5 Repository 与缓存

定义 LiveRepository、UserStateRepository、MediaRepository、ReminderRepository 协议。网络 DTO、领域模型、本地记录和 View state 分离，避免一个巨型 AppModel。

公共目录：版本化 JSON 写临时文件并原子替换；单项详情保存 eventID＋revision；bootstrap 完成后一次切换本地目录指针，下载失败保留旧版本。应用 delta 时在本地事务／批次中同时更新索引与数据引用，最后更新 cursor。

个人数据：独立 SwiftData 容器，不与公共缓存一起清理。图片缓存可限制 150 MiB，缩略图先行、全图按需、按版本失效；此数值为可调整初值。

全图缩放采用原生 UIScrollView 桥接或经过验证的原生图片查看实现，PDF 使用系统 PDFKit；图片解码降采样，避免在首页一次解码几十张超大商品表。

### 10.6 体验与无障碍

支持 Dynamic Type、VoiceOver、深浅色、Reduce Motion、至少系统推荐触控面积。日期／票务状态不能仅靠颜色。长日文标题保持可读，详情不截断；重要规则折叠前给出必须满足的条件摘要。

首次没有缓存时显示骨架与来源状态；离线有缓存可正常读；所有 Tab 无内容时显示“尚未获取／待核验”，不能默认显示“官方未公布”。

---

## 11. 提醒、安装身份与后续 iCloud 同步

### 11.1 为什么官方截止默认使用服务端提醒

本地通知可以根据已知时刻调度，但当 App 长期未运行、设备离线、或后台任务没有执行时，无法保证及时撤销一个后来被官方改期的旧本地通知。Apple 提供本地通知调度机制，但后台检查本身受到限制。[R05][R16]

因此首版默认：官方受付／付款／物贩／配信的可变截止提醒由服务端读取当前已发布版本，在发送前再次验证；用户自行设定的静态行程提醒可以使用本地通知。官方变化通知走 APNs。离线备份提醒属于显式开启的额外模式，文案标注“依据上次同步资料，请核对”，不能承诺绝不陈旧。

### 11.2 服务端动态提醒

Reminder 保存 installationID、entityID、deadlineField、offset、用户启用状态、scope、latestContentRevision、scheduledAt 和 deliveryMode。不要只保存一个固定 UTC 触发时刻而丢失它属于哪个官方字段。

发布新版本后重算受影响提醒；发送前重新读取 latest revision、字段知识状态、来源新鲜度和用户订阅。已取消、已付款（用户手动记录并同意用于提醒）、已关闭或截止删除的提醒取消。需要实时候选审核的字段不发送确定性截止提醒。

为同一安装、同一 reminder、同一 deadlineRevision、同一触发类型建立唯一 delivery key。APNs 使用正确环境、topic、expiration、collapse 标识；重试尊重响应并清理无效 token。APNs 不保证终端一定准时展示，App 应保留变更历史和手动核对入口。[R17]

### 11.3 本地通知

使用 UserNotifications；只在用户开启提醒时请求权限。先检查授权，安排或替换具有稳定 identifier 的请求；已过时的触发不登记。采用明确时区／绝对目标时刻，测试设备从多伦多切到日本后的行为。[R16]

本地与远程模式不能默认同时发送相同提醒。按 reminder 指定权威渠道，并在切换模式时撤销旧计划；设备离线时无法保证即时去重，须在 UI 说明并允许关闭离线备份。通知权限关闭时不能显示“提醒已生效”。

### 11.4 通知深链

通知载荷保存 notificationID、eventID、editionID?、stopID?、performanceID?、tab、cardKey、revision。点击后先验证实体／别名映射，再进入正确场次与卡片；若旧实体已撤回，进入更新说明，不打开另一场作为替代。

锁屏文案默认避免展示个人申请／付款状态；只呈现公演与公共更新。取消／延期属于高优先信息，但不能滥用需要特权的 Critical Alerts 权限。

### 11.5 匿名安装凭证

服务端注册生成随机 installationID 和不可猜测访问凭证，凭证放 Keychain；APNs token 只是投递地址，不是权限证明。更新／删除必须鉴权并确认属于该 installation。注册接口限流，可后续添加 App Attest 作为反滥用增强，不取代业务鉴权。

首版订阅可仅保存 event／performance IDs、语言、通知种类、时区和提醒规则；不收集票务密码、完整生日、支付信息或中签账号。日志不得输出 token、Keychain 凭证、用户私有备注。

### 11.6 iCloud 扩展方案（非首版阻塞项）

只同步用户关注、卡片布局、手动状态、提醒偏好，不同步公共演出库。继续通过 UserStateRepository 隔离实现。可使用独立的 SwiftData CloudKit 配置；需遵循兼容 schema、关系与唯一性限制，不能直接假设 CloudKit 能强制 SwiftData unique 约束。[R15]

每种偏好独立记录与稳定 key，避免整项公演偏好作为一块大 blob 冲突。布局可按 tab 保存一个原子记录，冲突采用明确的确定性选择并在多设备测试中验证；订阅开关和删除使用 tombstone，避免离线旧设备复活删除。

iCloud 同步与后端安装订阅是两条链：偏好同步到某设备后，该设备再对服务器安装订阅做幂等 reconcile。不能声称私人 CloudKit 变化会自动实时更新所有服务器订阅。退出 iCloud、不可用、额度问题时，保留本地操作，提供同步状态，不阻塞阅读。

---

## 12. 仓库组织与模块边界

```text
live-dashboard/
├── apps/
│   ├── ios/LiveDashboard/
│   │   ├── App/
│   │   ├── Features/Dashboard/
│   │   ├── Features/LiveDetail/{Overview,Tickets,Seating,Goods}/
│   │   ├── Features/MyLives/
│   │   ├── Features/CardSettings/
│   │   ├── Domain/{Models,ScopeResolver,StatusResolver,CardPolicy}/
│   │   ├── Data/{API,Repositories,Cache,Persistence}/
│   │   └── Services/{Media,Notifications,DeepLinks}/
│   └── server/
│       ├── api/
│       ├── admin/
│       └── workers/
├── packages/
│   ├── contracts/           # 版本化 JSON Schema／DTO 定义
│   ├── domain/              # 纯规则，不访问网络
│   ├── ingestion/           # scheduler、fetcher、adapters、validators
│   ├── publisher/           # 唯一公共发布入口
│   ├── notifications/
│   └── storage/
├── sources/
│   ├── registry.yaml
│   ├── seed_sources.json
│   └── selector-profiles/
├── db/migrations/
├── tests/
│   ├── fixtures/{BD01…BD10,LL01…LL10}/
│   ├── unit/
│   ├── contract/
│   ├── integration/
│   ├── security/
│   └── e2e/
├── infra/
│   ├── compose.yaml
│   └── deployment/
└── docs/{architecture,runbooks,source-review,release}/
```

iOS 首版保持一个 App target，不提前拆成大量内部 Package。后端一个 workspace，可独立运行 API、抓取与通知进程；更换 Adapter 不需要更新 App，增加新 CardKind 需要兼容策略或 App 更新。

---

## 13. 实施阶段、依赖与交付门槛

按里程碑推进，不以“页面看起来完成”代替端到端可用。并行开发只在契约冻结后进行。

| 阶段 | 必须交付 | 依赖 | 放行条件 |
|---|---|---|---|
| P0 来源与需求基线 | 注册表、条款／robots 审查、20 个候选状态、访问报告、需求追踪 | 无 | 候选和已核验事实明确隔离；至少一项双方企划的来源可合法取得或有审核输入路径。 |
| P1 数据契约与迁移 | 核心模型、范围／时间／金额、ID／别名策略、SQL、API schema | P0 | 同日两场、巡演、资格关联、未知范围的合成 fixture 可表达且验证通过。 |
| P2 抓取基础设施 | Fetcher、快照、限流、队列、lease、失败恢复、媒体准入 | P1 | 304／403／429／崩溃重试／SSRF 测试通过；未通过策略审查的来源不能被抓。 |
| P3 两家垂直切片 | BD01＋一个 Love Live! 多场样本：来源→候选→审核→API→原生详情 | P2 | 不手工硬编码正式公演数据即可生成可读卡片；每个关键字段可追溯。 |
| P4 完整提取与20例回归 | 全部模板族、物贩媒体、先行资格、配信、巡演关联 | P3 | 20 个候选逐项有 fixture 或明确 blocked 原因；不以空字段冒充提取成功。 |
| P5 发布与 API | 事务版本、审核后台、差分、游标、bootstrap、tombstone／remap | P1～P4 | 同一候选重复提交不重复发布；并发提交不漏增量；回滚可恢复。 |
| P6 原生 App 核心 | 首页、四分区、多场次、卡片设置、离线、来源说明、手动记录 | P1、P3、P5 | 场次切换不串数据，设置不被更新覆盖，清缓存不删用户记录。 |
| P7 提醒与隐私 | 安装鉴权、动态提醒、APNs、本地个人提醒、深链、删除 | P5、P6 | 改期、撤回、权限拒绝、token 更换、重试去重全部有测试。 |
| P8 运维与上线 | 部署、监控、备份恢复、资源限制、错误反馈、TestFlight 验收 | P4～P7 | Release 真机测试、持续采集试运行、恢复演练、来源权利／隐私检查通过。 |
| P9 可选扩展 | iCloud、Widget、日历、更多企划 | 首版通过 | 不改变公共库权威来源与原生核心结构。 |

P3 是最重要的早期验证点：一条真实可核验的全链路比二十张硬编码卡片更有价值。P5 的核心发布能力应随 P3 提供最小实现，随后补齐完整审核与增量功能；表中依赖表示最终交付，不要求人为阻止合理并行。

### 13.1 可以分派给 Agent 的工作包

采集 Agent：Fetch／Adapter／fixture，不写正式公共表。数据 Agent：schema／validator／publisher／API，不修改已冻结 iOS 导航。iOS Agent：基于契约和 fixture 建 UI／缓存，不内置官网解析。QA Agent：金标准与故障注入，不用解析器输出自动生成自己的预期值。

每个工作包交付代码、测试、变更说明和未验证项；不得将 UI 合成测试数据放进生产 seed。合并前由负责人核对契约版本与端到端测试。

---

## 14. 测试设计与20项回归清单

### 14.1 测试层次

单元测试覆盖时间／金额／范围／状态／URL／摘要规则。Adapter 测试仅使用已保存快照，避免 CI 反复请求官网；每份 fixture 标明来源、时间、许可／内部使用、解析版本和人工预期。网络在线 canary 在批准频率内独立运行，不和 PR 测试混为一谈。

Contract 测试：后端 JSON 与 Swift 解码一致，未知枚举不崩溃，currency／precision 不丢失。Integration 测试：数据库迁移、任务租约、Publisher、Outbox、分页与增量。iOS UI 测试：多个日期、深链、返回、字体、离线、配置恢复。

金标准必须由独立阅读来源的人标注。不能把 Adapter 自己的输出保存为 expected 后宣称“100% 正确”。未知／不适用字段也应被标注，避免错误地奖励乱填字段。

### 14.2 20个研究候选的结构回归目标

下表来自研究清单的测试需求，不是对公演全部事实的重新认证。只有取得支持的官方资料后才能把具体数值写入 golden fixture。

| ID | 样本 | 必测风险 |
|---|---|---|
| BD01 | BanG Dream! 13th☆LIVE | 三日及三套受付；单日高级票与通票同价不合并；按日物贩。 |
| BD02 | MyGO!!!!! 9th LIVE | 原场与神户版本独立；不继承错误嘉宾、票价和图片。 |
| BD03 | Morfonica Movement | 现场售罄、配信和单件商品库存独立。 |
| BD04 | Morfonica eleganza | 稀疏资料不虚构截止、价格或座位图。 |
| BD05 | Roselia 10th Anniversary Tour | 站点／场馆独立；专辑日期不是巡演日。 |
| BD06 | Roselia Lehre der Rose | 同名专辑、纪念Live、周年Tour不是同一实体。 |
| BD07 | Ave Mujica Exitus | 追加台北站的币种、时区、链接与日本站隔离。 |
| BD08 | RAS Boot IGNITION | 配信地区限制不污染现场资格；官方转售独立。 |
| BD09 | 夢限大 スーパーポジション | 混合活动类型；部分免费直播不等于整场免费。 |
| BD10 | DREAMS GO ON | CD／BD消费门槛不进入票价。 |
| LL01 | 15周年Fes | 按日出演与嘉宾；通贩截止／发货与开演分离。 |
| LL02 | 前夜祭Film Live | 两日昼夜场；现场／影像出演分开。 |
| LL03 | 石川大観光Ⅱ | 标题Ⅱ不是Day2；Day2先行资格不传播到Day1。 |
| LL04 | 106期新入生公演 | 普通票／U20分开；与103期公演不合并。 |
| LL05 | 103期卒業公演 | 逐日资格与嘉宾；尚未核验的场次数量不能盲目补齐。 |
| LL06 | Liella! 8th Tour | 不同发行商品对应不同城市／Day先行。 |
| LL07 | いきづらい部3rd | 保留_id；同艺人列表中的2nd／3rd受付不串。 |
| LL08 | いきづらい部2nd | 公演结束但配信／商品仍可能有效；商店全站通知隔离。 |
| LL09 | 虹咲8th | 两站多日；海外票务不是海外现场；回放日不是新增场。 |
| LL10 | 莲之空6th | Stage／城市／Day分开；受注与普通商品发货分开。 |

### 14.3 必须覆盖的故障与对抗输入

403、404、429、200 验证码、空 HTML、页面改版、重复标题、商店页脚多余日期、同 URL 图片更新、301 跳转商店首页、跨域 URL、超大压缩响应、SVG 外链、恶意 HTML／prompt injection、错误系统时间、跨年、24:00、日期精度未知。

并发测试：两个 worker 重复领取、旧 lease 回写、发布失败后重试、Outbox 重复投递、全局游标事务提交顺序、客户端拉取途中公演变更、旧快照重放、bootstrap 失败回退。

提醒测试：官方改期而 App 未启动、取消后通知任务仍在队列、权限拒绝、token 轮换、安装删除、离线备份去重局限、用户选定场次被 remap、时区旅行、相同提醒重复调度。

### 14.4 建议验收指标

以下为首版工程目标，不是现有性能：

| 类别 | 目标 |
|---|---|
| 核心字段证据覆盖 | 已发布公演日期／票价／截止／资格／座位图用途 100% 可回溯。 |
| 结构准确性 | 人工审核的回归集零跨场次关键事实污染。 |
| 首次身份审核 | 20 个候选全部有明确处理结论；未核验项不进入正式公演。 |
| 采集故障安全 | 失败／空解析不会清空 last-known-good；阻断状态可观察。 |
| 内容检测目标 | 已批准且健康的临近资料，目标在其计划抓取间隔＋排队时间内被发现；人工审核延迟单独统计。 |
| iOS缓存首屏 | 基准真机 Release 构建下 p95 < 1 秒；测试条件写入报告。 |
| 场次切换 | 已缓存数据 p95 < 100 ms，不触发必需网络请求。 |
| API摘要 | 自有测试网络及负载下 p95 < 500 ms；第三方抓取不占用 API 请求链。 |
| 稳定性 | 长时间切场／读图／离线恢复无已知崩溃，无持续内存增长。 |
| 运行观察 | 建议至少连续7天试运行＋合成改期／撤回测试；没发生真实变更不等于已验证变更链。 |

不能以“API返回200”“解析器无异常”替代字段正确率。分别报告 availability、parse coverage、fact accuracy、review delay、published freshness。

---

## 15. 部署、监控、安全与维护

### 15.1 环境

开发使用 Docker Compose：PostgreSQL、API／admin、scheduler、fetch worker；浏览器 worker 可选启动。生产将浏览器放到独立受限容器，非root运行、只允许外部批准来源访问、无数据库发布权限、只读文件系统＋临时下载目录、CPU／内存／执行时长上限。

开发／预发布／生产数据库和 APNs 环境隔离。部署者需要配置自有 API 域名、TLS、数据库、BlobStore、管理员身份提供者、Apple Team／Bundle／APNs 凭据。文档不捏造这些值。

### 15.2 CI/CD

后端：lint → typecheck → schema与migration检查 → unit → fixture → contract → DB integration → build → security tests。iOS：编译 → 领域模型与解码测试 → UI tests → Release 构建 → 真机关键场景 → TestFlight。

锁定依赖与镜像版本，定期依赖审查。数据库使用向前兼容的 expand／migrate／contract 迁移，先部署兼容 API 再移除旧字段。适配器可独立回滚；保留上一个正常 parser profile。

### 15.3 监控指标

按来源记录：请求成功／失败／阻断、304比例、响应大小、队列延迟、最近成功时间、未解析模板数、关键字段覆盖、候选冲突数、图片变更数。按发布记录：已接受事实、审核等待、回滚、Outbox积压。按客户端记录必要的匿名崩溃／性能，不采集票务私人信息。

来源长期健康但关键字段突然大量丢失，应报警而不是继续发布。单来源短期错误激增暂停该 adapter 自动发布；单张卡显示资料状态，整个 App 仍可读缓存。

### 15.4 备份与恢复

数据库每日备份；条件允许时启用 point-in-time recovery。重要 BlobStore 对象版本化，校验快照 hash。至少执行一次从备份恢复数据库、来源配置、发布版本和通知订阅的演练，不能只确认“备份命令成功”。

恢复后默认暂停通知投递，检查 last-delivered 与 outbox 状态，避免恢复旧备份后重发一批过期提醒。恢复游标仍需遵循日志保留／bootstrap规则。

### 15.5 运维 Runbook

来源403：暂停→核验条款／站点变化→人工来源路径→恢复前canary；模板变化：保留旧数据→保存新快照→更新profile→回放20例→渐进发布；错误公演数据：冻结相关候选→发布修正／回滚→评估是否发更正提醒；误合并：拆分→remap→迁移用户引用；漏提醒：检查订阅、来源新鲜度、review、outbox、APNs，不直接承诺补发可以挽回截止。

### 15.6 成本边界

首版不依赖付费抓取代理、付费大模型或专有内容 API。选择自托管普通服务＋数据库＋有限存储即可验证全链路，但这不等于永久免费；服务器、域名、存储和 Apple 发布条件需要单独预算。

先统计每日请求数、动态浏览器运行时长、快照字节、图片流量、活跃安装、通知数，再按实际服务商报价估算；此计划不提供未经核验的固定月费。流量增长优先减少重复抓取、增加 API 缓存，再考虑拆分基础设施。

### 15.7 上架检查

保持独立信息工具定位，不暗示官方出品；仅展示具有适当权限的内容和素材。准备来源说明、隐私政策、数据删除入口、来源纠错入口和审核演示数据。App Review 对第三方服务与素材权限有明确要求；上线前重新核查适用条款，不以本计划代替授权。[R10]

现场票／实体商品与数字配信购买入口分开审查。App Store 对App外消费的实体商品／服务和数字内容购买链接适用不同规则，且数字外链要求可能因 storefront 和功能而异；不因“用Safari打开”就默认豁免。首版不在App内播放或解锁付费配信，配信购买入口是否展示需按具体发行区域和审核方案确认，不能通过隐藏功能绕过审核。[R10]

---

## 16. 最终交付清单与执行顺序

首版交付应包含：可编译 iOS 项目、可部署后端、sources 注册表、SQL migrations、版本化 API schema、全部 Adapter 与 fixture、审核后台、采集／发布／提醒运行说明、备份恢复说明、20项回归报告、Release 真机验收报告及已知限制。

最先实现的闭环：**批准来源 → 保存真实快照 → 提取一个多日公演 → 审核 → 发布 API → iOS 按日切换 → 来源变化后重发版本 → 用户偏好仍保留。**完成后再扩展模板和媒体，不先制作大量不可更新的演示卡片。

给开发 Agent 的约束：不得编造 DOM 选择器已验证、不得使用搜索摘要当生产字段、不得把 seed 标题／研究说明当事实、不得静默丢弃范围、不得绕过 Publisher 写正式数据、不得声称提醒或 iCloud 必然即时送达。所有未验证项进入 source report／review queue，而非用看似合理的值补齐。

---

## 17. 附件说明

- `source_registry.yaml`：待审来源与抓取策略建议。全部来源默认 disabled／pending_review，不含已验证选择器。
- `seed_sources.json`：从研究文件无损提取的52个URL及20个候选关联；所有归属与访问状态仍待生产核验。
- `implementation_backlog.json`：带依赖、交付物、验收条件的分阶段任务，不代表任务已完成。
- `reference/live_dashboard_20_sources_and_ui.json`：原始研究清单，保留原声明，供追踪与回归设计。

这些附件与本计划共同构成实施输入，不是已部署应用或实时数据库。

---

## 18. 参考来源与核验范围

以下为本次规划所依据的官方文档／标准和实际读取的页面；访问日期为2026-09-22。库／平台事实来自文档，具体工程参数是本计划的设计选择。

- [R01] Node.js Releases：<https://nodejs.org/en/about/previous-releases>。本次页面列 Node 24 为 LTS，Node 18／20 为 EOL。
- [R02] Cheerio Loading Documents：<https://cheerio.js.org/docs/basics/loading/>。字节加载、编码识别与DOM解析。
- [R03] Playwright Network：<https://playwright.dev/docs/network>。监测／限制浏览器网络请求。
- [R04] PostgreSQL SELECT：<https://www.postgresql.org/docs/current/sql-select.html>。SKIP LOCKED 的队列表使用场景。
- [R05] Apple Background Tasks：<https://developer.apple.com/documentation/backgroundtasks>；Apple工程师关于后台检查限制的答复：<https://developer.apple.com/forums/thread/786844>。文档页面动态加载，相关限制由官方搜索摘要和工程师答复核对。
- [R06] Bushiroad Live 商品列表：<https://bushiroad-store.com/blogs/live>。本次成功读取按公演／Day组织的列表及页脚通用条款。
- [R07] School idol STORE：<https://lovelive.fannect.jp/>。本次成功读取首页；各批次与历史链接仍需单独核验。
- [R08] OWASP SSRF Prevention：<https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html>。
- [R09] RFC 9309：<https://www.rfc-editor.org/rfc/rfc9309.html>。robots协议及其不构成访问授权的说明。
- [R10] Apple App Review Guidelines 5.2／5.2.2：<https://developer.apple.com/app-store/review/guidelines/>。第三方素材与服务使用要求。
- [R11] RFC 9110：<https://www.rfc-editor.org/rfc/rfc9110.html>。HTTP条件请求、响应与状态语义。
- [R12] e+ BanG Dream! 13th☆LIVE：<https://eplus.jp/sf/detail/4529430001>。本次成功读取分Day／分受付正文；平台说明状态可能不实时，不应据此承诺库存。
- [R13] Fastify Validation and Serialization：<https://fastify.dev/docs/latest/Reference/Validation-and-Serialization/>。
- [R14] Apple SwiftUI / Managing Model Data：<https://developer.apple.com/documentation/swiftui>；<https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app>。原生UI和模型状态管理参考，具体页面依赖动态加载。
- [R15] Apple SwiftData CloudKit Sync：<https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>。本次搜索摘要明确提到 CloudKit 无法强制 unique；部署前应按完整文档核查兼容模型。
- [R16] Apple Scheduling a Local Notification：<https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app>。
- [R17] Apple Remote Notification Server：<https://developer.apple.com/documentation/usernotifications/setting-up-a-remote-notification-server>。APNs实施需进一步按当前文档测试服务器与真机。

研究文件为本对话提供的原始输入，不是官方一手数据；其52个URL的逐项正文、图片和字段正确性仍属于P0／P4工作。
