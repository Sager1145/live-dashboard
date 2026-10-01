# Live Dashboard

BanG Dream! 与 Love Live! 公演资料的原生 iOS App。官网采集由 GitHub Actions 集中执行，公开资料以 GitHub Pages JSON 快照发布，App 只同步结果并离线缓存。无需部署 PostgreSQL、API 服务或树莓派。

## 集中采集与发布

每小时第 17 分钟自动执行一次采集，也可从独立抓取入口或 GitHub Actions 的 Run workflow 手动启动。GitHub Actions 的定时任务可能延迟，不保证整点准时。网站首页仅显示「正在构建中，当前不可用」，没有 dashboard UI，也没有抓取入口或数据接口的导航。

配置与接口说明见 [Pages 采集与发布](docs/PAGES_CATALOG.md)。官网部分失败时保留已有资料及已归档公演；首次采集完全没有可用资料时停止发布，避免空快照覆盖有效数据。

## App 运行

用 Xcode 打开 `ios/LiveDashboard.xcodeproj`，选择 `LiveDashboard` scheme（iOS 18+）。数据接口固定在代码内部；App 的设置、界面和错误信息不显示网站或接口地址。

- App 在前台每小时同步一次；回到前台时检查是否需要同步，支持手动同步。系统挂起 App 时不保证每小时运行，恢复前台后补同步。
- 全量同步、公演刷新、卡片刷新及历史资料查询都读取已发布的同一份快照，不触发手机直接抓取官网。
- 公演资料保存在 Application Support，离线或下载失败时保留缓存；关注、申请记录、提醒和卡片设置独立保存在 SwiftData。
- 首页按公演日期排列，图片、票务、场次和详情沿用现有数据模型。历史查询只查询集中目录已经收录的公演。
- 官网未能明确解析的字段不推测填充；模板变化仍需要维护共用解析器。

## ChatGPT 助手（可选）

在「设置 → ChatGPT 账号与 AI 整理」可用 ChatGPT 账号（OAuth 2.0 + PKCE，默认使用 OpenAI 官方 ChatGPT 登录客户端，回调 `http://localhost:1455/auth/callback` 由 App 内置的本机回调服务接收；也可填写自己注册的 Client ID 与回调地址）或 OpenAI API Key 登录。凭据保存在本机钥匙串，可随时退出登录。

模型按实际连接方式分别保存：ChatGPT/Codex 默认 `gpt-6-luna`，OpenAI API 默认 `gpt-5-mini`。旧版 ChatGPT 登录使用的 `gpt-5-mini` 会自动迁移，自定义模型保留。ChatGPT 登录显示 Codex 推荐模型（实际可用性取决于账号权限），API Key 登录可载入 API 模型列表；选择后可用「测试连接」验证。修改模型或重新登录后，之前失败的自动整理可在下次刷新时重试。

登录后，详情页顶部出现「AI 整理结果」卡片，工具栏「AI 整理」可随时重新生成；开启「官网资料更新后自动整理 AI 字段」则每次官网整理后只为内容有变化的公演生成。完整数据与摘要由 OpenAI Responses API 以固定 JSON 结构返回：

- 每次 AI 整理先重新读取当前 Live 的官网页面，独立分析活动、场次、时间、场馆、出演、票价、入场、售票轮次、特典、配信、座位与周边；结果写入独立的完整 Live 数据，详情页的「官网抓取 / AI 重新整理」切换概览、票务、座位、周边的实际字段。补充信息在「AI 整理字段」按类别展开，官网未公布的字段保留占位，允许与规则抓取的内容不同。
- 多日公演按场次分别总结（每场只写本场差异），共通内容进入总览与重点；随场次选择器切换。
- 重点按类别（日程、售票、周边、座位、配信、公告）与重要度排列，日期、价格、截止／中止等关键内容用不同颜色与字重突出。
- 售票页与周边页底部列出 AI 识别的售票链接和通贩／贩售链接；只接受官网页面中实际出现的 URL，模型给出的其他链接会被丢弃并在“需要核对”中提示。
- 摘要与官方资料分开保存（Application Support/LiveDashboard/Assistant），不写入公演资料，卡片明确标注“非官方资料，请以官网为准”；官网内容变化后卡片显示“摘要可能过期”。
- 生成成功后自动保存到本机；退出登录后仍可查看。卡片的「删除本公演 AI 结果」只删除当前 Live 的 AI 结果，并暂停其自动生成，手动重新整理成功后恢复。保存或删除失败会显示错误。
- 使用助手会把官网页面文字与已解析的结构化资料发送到 OpenAI；不登录时不会发送任何数据到 OpenAI；尚无保存结果时，详情页的「AI 整理结果」卡片提示如何开启，可在卡片设置中隐藏。

原有 PostgreSQL 后端及本机采集实现保留为历史工具与测试实现，以下服务器运行、审核及 APNs 部署步骤不是当前 App 的运行前提。

## 可选后端运行

需要 Node **24.21.0**、PostgreSQL **18.6**、Xcode（iOS 18+ SDK）。

```sh
cp .env.example .env
# 设置随机 POSTGRES_PASSWORD、ADMIN_TOKEN
# Docker Compose（从仓库根目录执行）：
docker compose --env-file .env -f infra/compose.yaml up --build
```

不使用 Docker 时先准备 PostgreSQL，然后：

```sh
cd server
npm ci
export DATABASE_URL='postgresql://livedash:YOUR_PASSWORD@localhost:5432/livedash'
export ADMIN_TOKEN='YOUR_RANDOM_ADMIN_SECRET_AT_LEAST_24_CHARACTERS'
npm run migrate
npm run dev
# 分别在其他终端运行：npm run scheduler / npm run worker / npm run notify
```

API 默认 `127.0.0.1:3000`。后台 `/admin` 使用 HTTP Basic，用户名 `admin`，密码为 `ADMIN_TOKEN`；公网部署必须经 HTTPS 反向代理。公开 API 与管理路由分离，App 无法写入公共公演事实。

当前 App 默认读取 Pages 快照，不读取此 API；`APILiveRepository` 保留供后端契约测试与开发集成使用。

## 第一条真实快照链路

在 `server/` 中执行：

```sh
npm run cli -- seed
npm run cli -- import-snapshot 'https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest' tests/fixtures/snapshots/lovelive_detail_15th_lovelivefest.html
# 使用上一条返回的 snapshotID：
npm run cli -- propose SNAPSHOT_UUID
```

到后台对比候选、原文快照和适用场次，填写审核原因并核验，再发布。解析结果不会自动变成已确认数据。遇到不支持的模板或未明确的范围，候选留在审核队列，不推测补值。线上抓取需要分别完成来源策略审核及文档启用；导入已保存的公开快照不会启用定时抓取。

## 验证

```sh
cd server
npm run typecheck
npm test
npm run build
# 用独立测试 PostgreSQL 18 运行并发集成测试：
TEST_DATABASE_URL='postgres://...' npm test
```

默认数据库测试使用真实 PostgreSQL 查询引擎 PGlite，外部 PostgreSQL 18 测试单独标识；CI 提供 PostgreSQL 18 服务。iOS 构建及模拟器测试命令见 [运行与恢复](docs/OPERATIONS.md)。

## 主要目录

| 路径 | 内容 |
|---|---|
| `server/src/ingestion` | 来源限制、DNS/IP 检查、条件请求、真实快照解析器 |
| `server/src/publisher.ts` | 审核、证据验证、不可变版本、目录游标、Outbox |
| `server/src/api.ts` | 公共 API、安装鉴权、服务端审核后台 |
| `server/src/notifications` | 截止规则、APNs HTTP/2、签名与重试 |
| `server/db/migrations` | SQL 数据模型及关系约束 |
| `ios/` | SwiftUI App、Pages 同步、共用官网采集器、SwiftData 用户数据 |
| `web/` | 网站占位页、独立抓取入口 |
| `.github/workflows/pages-catalog.yml` | 每小时采集、持久快照与 Pages 发布 |
| `sources/` | 默认禁用的来源注册表和研究 URL |
| `fixtures/contracts/` | 明确标记的跨端合成测试数据，含 v1 与 v2 |
| `schema/v2/` | 由 Zod 导出的 v2 JSON Schema |
| `docs/adr/0001-shared-contract-v2.md` | 已冻结的共享契约与身份映射 |
| `infra/` | 容器部署、数据库权限模板 |

状态与限制以 [验收报告](docs/IMPLEMENTATION_STATUS.md)、[来源报告](docs/SOURCE_REPORT.md) 为准。APNs 真机、TestFlight、生产恢复和持续采集需要真实部署环境；不能用本地测试代替这些验收。

## 官网数据对比测试

[2026-09-22 详细审计报告](docs/audits/2026-09-22/README.md)记录按官网发布时间选样、逐场预期值、修复前后输出、图片访问检查和 iOS 回归测试。可使用 `scripts/audit/run-official-audit.sh` 回放已保存官网 HTML，或加 `--live` 运行 App 的实际抓取器。Love Live! 的当前网络访问限制单独记录，未计为字段解析通过。

## 隔离的本地真实快照预览

开发者可创建专用、名称以 `_preview` 结尾的空 PostgreSQL 数据库，在 `server/` 执行：

```sh
PREVIEW_DATABASE_URL='postgres://.../livedash_preview' node --import tsx scripts/preview-fixtures.ts
node --import tsx scripts/start-preview.ts
```

此脚本将已保存的 BD01／LL01 官方快照用于本地集成预览，并自动通过仅用于该预览的审核步骤；它拒绝普通生产库名称，不是正式资料审核流程。配置保存在忽略提交的 `.runtime/preview-env.json`。该预览仅供后端集成调试，当前 App 不连接此预览 API。
