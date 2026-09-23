# Live Dashboard

BanG Dream! 与 Love Live! 官方公演资料的独立原生 iOS Dashboard。App 直接抓取官网并在设备上整理、持久保存，不需要部署 API、数据库或采集服务器。

## App 本地运行

用 Xcode 打开 `ios/LiveDashboard.xcodeproj`，选择 `LiveDashboard` scheme（iOS 18+）。不需要设置 API 地址。

首页按公演日期从早到晚排列，同日按开演时间排序，日期待定的公演放最后。多日公演按最早一场排序，卡片显示完整日期范围及官网公演主视觉缩略图；重新整理后同步更新图片。

- 按手机当前显示的日期判断跨天，不换算官网时区。每天首次打开或跨天回到前台时自动整理；同一天只自动尝试一次，失败可手动重试。
- 演出页下拉、工具栏和设置页均可手动整理。长按公演卡片可只整理该公演；详情资料卡片的菜单可只重新整理选中卡片。单卡手动整理允许重查已归档的旧演出，不更新全量整理的每日标记。
- 更新窗口从手机当前日期往前 **一个自然月** 开始，包含边界日期及所有未来演出；巡演按最后一场判断，日期待定的演出继续检查。
- 已保存且全部场次早于窗口的演出冻结保留，不再请求其详情。新发现的窗口外历史演出不补抓。
- 资料保存在 Application Support，重启后可离线查看；抓取失败保留原资料，可手动重试。关注、申请记录和卡片设置仍独立保存在 SwiftData。
- 官网未能明确解析的字段不推测填充，详情可打开官方来源。网页模板变化需要更新相应解析器。
- 周边、座位等资料含实际图片时直接显示在卡片内，卡片上只显示图片、说明和“分享”按钮，点击图片后放大查看并显示原图地址与官方来源；每张图片（含首页主视觉缩略图）都有“分享”按钮，通过系统分享面板可存到相册、文件或发给他人，原图字节不经重新编码；卡片保留原图地址和官方来源。只有网页链接的资料仅显示链接。
- 售票轮次与周边批次会完整保留官网该区块内的全部链接（售票平台、通贩商店等）并按原文标签显示；官网未给出链接时不补链接。

## ChatGPT 助手（可选）

在「设置 → ChatGPT 账号与 AI 整理」可用 ChatGPT 账号（OAuth 2.0 + PKCE，默认使用 OpenAI 官方 ChatGPT 登录客户端，回调 `http://localhost:1455/auth/callback` 由 App 内置的本机回调服务接收；也可填写自己注册的 Client ID 与回调地址）或 OpenAI API Key 登录。凭据保存在本机钥匙串，可随时退出登录。

模型按实际连接方式分别保存：ChatGPT/Codex 默认 `gpt-6-luna`，OpenAI API 默认 `gpt-5-mini`。旧版 ChatGPT 登录使用的 `gpt-5-mini` 会自动迁移，自定义模型保留。ChatGPT 登录显示 Codex 推荐模型（实际可用性取决于账号权限），API Key 登录可载入 API 模型列表；选择后可用「测试连接」验证。修改模型或重新登录后，之前失败的自动整理可在下次刷新时重试。

登录后，详情页顶部出现「AI 整理摘要」卡片，工具栏「AI 整理」可随时重新生成；开启「官网资料更新后自动生成摘要」则每次官网整理后只为内容有变化的公演生成。摘要由 OpenAI Responses API 以固定 JSON 结构返回：

- 多日公演按场次分别总结（每场只写本场差异），共通内容进入总览与重点；随场次选择器切换。
- 重点按类别（日程、售票、周边、座位、配信、公告）与重要度排列，日期、价格、截止／中止等关键内容用不同颜色与字重突出。
- 售票页与周边页底部列出 AI 识别的售票链接和通贩／贩售链接；只接受官网页面中实际出现的 URL，模型给出的其他链接会被丢弃并在“需要核对”中提示。
- 摘要与官方资料分开保存（Application Support/LiveDashboard/Assistant），不写入公演资料，卡片明确标注“非官方资料，请以官网为准”；官网内容变化后卡片显示“摘要可能过期”。
- 使用助手会把官网页面文字与已解析的结构化资料发送到 OpenAI；不登录时不会发送任何数据到 OpenAI；详情页的「AI 整理摘要」卡片仅提示如何开启，可在卡片设置中隐藏。

原有后端保留为可选工具与历史实现，以下服务器运行、审核及 APNs 部署步骤不再是 App 的运行前提。

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

当前 App 默认使用本机官网采集，不读取此 API；`APILiveRepository` 保留供后端契约测试与开发集成使用。

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
| `ios/` | SwiftUI App、URLSession Repository、SwiftData 用户数据 |
| `sources/` | 默认禁用的来源注册表和研究 URL |
| `fixtures/contracts/` | 明确标记的跨端合成测试数据 |
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
