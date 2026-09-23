> 历史设计记录：本文保留原型阶段内容。当前实现与验收以 [完整计划](FULL_IMPLEMENTATION_PLAN.md)、[API 契约](API_CONTRACT.md) 和 [验收报告](IMPLEMENTATION_STATUS.md) 为准。当前范围只接受显式 Performance ID 集合或 unconfirmed；不再使用动态 wholeEvent／stop 范围。

# 实施计划

本计划是 `DESIGN.md` 第八节「实施顺序与验收标准」的展开版本，将三个阶段拆解为具体交付物、所在仓库目录、交付物之间的依赖关系，以及每个验收场景在哪里被验证。

## 当前状态

- `docs/DESIGN.md`、`docs/API_CONTRACT.md` 已完成，作为数据模型与实施范围的基准文档。
- 15 份官方页面 HTML 快照已于 **2026-09-22** 抓取完成（curl，桌面浏览器 UA，`Accept-Language: ja`），全部返回 **HTTP 200**；清单与来源 URL 见 `server/tests/fixtures/snapshots/MANIFEST.md`。
- iOS 骨架（Swift 包 `LiveDashboardKit` ＋ Xcode App 工程）与服务端（Python 采集服务）正在**并行搭建**，均处于早期脚手架阶段，尚未实现解析器与页面。

## 仓库目录约定

| 目录 | 内容 |
|---|---|
| `ios/` | SwiftUI App 工程 + Swift 包 `LiveDashboardKit`（`Domain`、`Data`、`Features`、`Services` 等，对应 DESIGN.md 第六节的目录结构）。Swift Testing 测试与被测代码同包存放。 |
| `server/` | Python 采集服务：发现、抓取、快照存储、解析适配器、字段校验、发布。`server/tests/` 存放 pytest 测试与 `fixtures/snapshots/` 下的 HTML 快照。 |
| `schema/` | `LiveEventBundle` JSON Schema（与 `docs/API_CONTRACT.md` 对应），供服务端发布校验与 iOS 端解码测试共用。 |
| `fixtures/` | 跨语言共享的示例数据（例如序列化后的 `LiveEventBundle` 样例），供 iOS 与服务端测试对照使用。 |
| `docs/` | 设计与实施文档（本文件及相关文档）。 |

---

## 阶段一：数据基础

对应 DESIGN.md 第八节「数据基础」：官方来源登记、代表性页面快照、各模板解析器、统一模型、来源证据和审核流程。

### 交付物

| 交付物 | 目录 | 说明 |
|---|---|---|
| 官方来源登记表 | `docs/SOURCES.md` | 列出 DESIGN.md 第一节的全部官方入口、对应适配器、抓取频率建议、快照文件名。 |
| 代表性页面快照 | `server/tests/fixtures/snapshots/` | 已完成：15 份 HTML 快照（2026-09-22 抓取，HTTP 200），见 `MANIFEST.md`。 |
| 统一数据模型（Python 端） | `server/` | 对应 `LiveEvent`／`LiveStop`／`Performance`／`TicketTier`／`TicketRound`／`TicketOffer`／`GoodsCampaign`／`MediaAsset`／`Notice`／`SourceEvidence` 等实体，与 `docs/API_CONTRACT.md` 的 `LiveEventBundle` 字段一一对应。 |
| JSON Schema | `schema/` | `LiveEventBundle` 契约的机器可读定义，供发布前校验。 |
| 各模板解析适配器 | `server/`（例如 `BangDreamEventIndexAdapter`、`BangDreamEventDetailAdapter`、`BushiroadLiveGoodsAdapter`、`LoveLiveIndexAdapter`、`LoveLiveDetailAdapter`、`LoveLiveLegacyPageAdapter`、`LoveLiveNewsAdapter`、`LoveLiveGoodsStoreAdapter`） | 针对 DESIGN.md 第二节列出的两家官网、新旧模板分别实现，输入为快照 HTML，输出为候选记录。 |
| 来源证据与字段校验 | `server/` | 生成 `SourceEvidence`（来源 URL、原文引用、来源发布时间、核对时间、核验状态），拒绝未经校验的抓取结果直接覆盖线上数据。 |
| 简单审核流程 | `server/` | 解析异常、模板变化、来源冲突、价格或时间异常时进入人工审核，保留上一次已确认版本。 |

### 依赖关系

1. `docs/SOURCES.md` 依赖已抓取的快照（已完成）与 DESIGN.md 第一、七节的规则。
2. 各解析适配器依赖对应的 HTML 快照作为测试输入，且依赖统一数据模型先定义字段。
3. 来源证据与审核流程依赖统一数据模型（`SourceEvidence` 引用其他实体的记录 ID）。
4. JSON Schema 依赖 `docs/API_CONTRACT.md` 定稿（已完成），并反过来约束适配器输出。

### 验收映射

| 验收场景（DESIGN.md 第八节） | 验证位置 |
|---|---|
| 旧网页或店铺迁移：保留身份与迁移关系，不误报公演消失或通贩结束 | `server/tests/`：针对 `lovelive_store_portal.html` → `lovelive_legacy_goods_store_redirect.html` → `lovelive_fannect_store.html` 迁移链的 pytest 用例（占位测试名 `test_lovelive_goods_store_alias_chain`） |
| 抓取失败／字段缺失：保留确认数据，明确显示核对问题，不冒充「官方未公布」 | `server/tests/`：模拟解析异常场景的 pytest 用例（占位测试名 `test_parse_failure_preserves_last_confirmed_and_flags_status`），断言产出状态为 `parseFailed` 而非 `officiallyTBA` |
| 一个通贩页关联多日：正确标记共通范围，不为每一天复制出互相冲突的数据 | `server/tests/`：以 `bushiroad_goods_bangdream13th_day1.html`／`bushiroad_goods_avemujica_tour2026.html` 为输入的 pytest 用例（占位测试名 `test_goods_campaign_scope_resolution`），断言 `Scope` 输出符合 `wholeEvent`／`stop`／`performances`／`unconfirmed` 语义 |

---

## 阶段二：核心 App

对应 DESIGN.md 第八节「核心 App」：首页公演卡片、四个详情 Tab、多场次切换、完整物贩图片、卡片配置、关注及离线缓存。

### 交付物

| 交付物 | 目录 | 说明 |
|---|---|---|
| `LiveDashboardKit`（Domain 层） | `ios/LiveDashboardKit/Sources/Domain/` | `Models`（对应 `docs/DATA_MODEL.md` 中的实体）、`PerformanceScopeResolver`、`TicketStatusResolver`、`ImportantInformationPolicy`。 |
| `LiveDashboardKit`（Data 层） | `ios/LiveDashboardKit/Sources/Data/` | `APIClient`（解码 `LiveEventBundle`）、`LiveRepository`、`Persistence/`（SwiftData）、`MediaCache/`。 |
| App target（Features 层） | `ios/LiveDashboardApp/`（依赖 `LiveDashboardKit`） | `Dashboard`（首页卡片流）、`LiveDetail/Overview`、`LiveDetail/Tickets`、`LiveDetail/Seating`、`LiveDetail/Goods`、`MyLives`、`CardSettings`。 |
| 多场次切换机制 | `ios/LiveDashboardKit/Sources/Domain/`＋`ios/LiveDashboardApp/App/` | 统一 `selectedPerformanceID`，四个 Tab 共享。 |
| 卡片配置持久化 | `ios/LiveDashboardKit/Sources/Data/Persistence/` | `CardConfiguration`／`UserEventState`，与公共缓存分开存储。 |
| 离线缓存 | `ios/LiveDashboardKit/Sources/Data/Persistence/`＋`MediaCache/` | SwiftData 本地快照 + 图片缓存，支持离线阅读。 |

### 依赖关系

1. Domain 层模型依赖 `docs/API_CONTRACT.md`／`schema/` 中定稿的 `LiveEventBundle` 结构（阶段一产出）。
2. `LiveRepository` 依赖服务端已发布的数据版本（阶段一的采集与发布流程）；开发期可用 `fixtures/` 中的样例数据先行解耦联调。
3. 首页卡片与详情 Tab 依赖 Domain 层的 `PerformanceScopeResolver`／`TicketStatusResolver`／`ImportantInformationPolicy` 先行实现。
4. 卡片配置与离线缓存依赖 Data 层持久化方案先确定（SwiftData 模型）。

### 验收映射

| 验收场景 | 验证位置 |
|---|---|
| Day1 切换到 Day2：概要、价格、售票链接、座位和场贩范围全部一致切换 | `ios/LiveDashboardKit/Tests/`：Swift Testing 用例（占位测试名 `PerformanceSwitchingTests.testAllTabsFollowSelectedPerformanceID`） |
| 同日昼夜场：开场／开演时间及出演者不会混用 | `ios/LiveDashboardKit/Tests/`：（占位测试名 `PerformanceScopeResolverTests.testSameDayMatineeEveningNotMerged`） |
| 多轮受付同时存在：每轮时间、资格和价格关系独立，旧轮次不会覆盖新轮次 | `ios/LiveDashboardKit/Tests/`：（占位测试名 `TicketStatusResolverTests.testConcurrentRoundsRemainIndependent`） |
| 用户配置后更新数据：隐藏、排序、置顶和提醒设置不会重置 | `ios/LiveDashboardKit/Tests/`：（占位测试名 `CardConfigurationTests.testConfigSurvivesDataRefresh`），断言配置绑定卡片类型＋实体 ID 而非数组下标 |
| 图片更换但 URL 不变：能识别新版本，并更新对应图片卡片 | `ios/LiveDashboardKit/Tests/`：（占位测试名 `MediaCacheTests.testContentChangeDetectedWithoutURLChange`） |
| 离线、重启、大字体：已缓存详情可读，选择状态合理恢复，文字和控件不被裁切 | `ios/LiveDashboardApp/UITests/` 或 `LiveDashboardKit/Tests/`：（占位测试名 `OfflineRestoreTests.testCachedDetailReadableAfterRestart`） |

---

## 阶段三：追踪增强

对应 DESIGN.md 第八节「追踪增强」：重要变化记录、截止提醒、个人申请状态；随后再增加 iCloud 同步、日历和 Widget。

### 交付物

| 交付物 | 目录 | 说明 |
|---|---|---|
| 重要变更记录生成 | `server/` | 服务端在发布新版本时比对差异，生成变更记录（对应 DESIGN.md 第七节 3.「后来才出现的变化」）。 |
| 远程提醒下发 | `server/`＋`ios/LiveDashboardKit/Sources/Services/ReminderService` | 服务端发现新轮次／时间变更／座位图后触发远程通知；App 端接收并深链到正确公演／场次／Tab／卡片。 |
| 本地截止提醒 | `ios/LiveDashboardKit/Sources/Services/ReminderService` | 用户选择后使用本地通知安排（例如申请截止前一天），截止时间改变时替换旧提醒。 |
| 个人申请状态记录 | `ios/LiveDashboardKit/Sources/Data/Persistence/` | 「我已申请」「我已付款」「我已有基础票」等用户手动记录，仅影响个人提醒，不改写官方票务事实。 |
| （后续）iCloud 同步 | `ios/LiveDashboardKit/Sources/Data/Persistence/` | 用户数据（关注、配置、申请记录）的 CloudKit 兼容存储，与公共缓存分离。 |
| （后续）日历导出、Widget | `ios/LiveDashboardApp/` | 依赖前述阶段的稳定数据模型与提醒机制。 |

### 依赖关系

1. 变更记录生成依赖阶段一的发布流程（版本化的 `LiveEventBundle`）已能持续运行。
2. 远程提醒依赖变更记录生成，且依赖阶段二的深链路由（`selectedPerformanceID`＋Tab＋卡片定位）已实现。
3. 本地截止提醒依赖阶段二的 `TicketRound`／`GoodsCampaign` 时间字段已可在 App 内读取。
4. iCloud 同步、日历、Widget 为后续增量项，依赖前述用户数据持久化方案（阶段二）稳定后再引入，不阻塞前两个阶段。

### 验收映射

| 验收场景 | 验证位置 |
|---|---|
| （变更记录与提醒的深链正确性，属于验收表之外的追踪增强专项验证，随迭代补充） | `server/tests/`（变更比对逻辑）＋`ios/LiveDashboardKit/Tests/`（提醒深链，占位测试名 `ReminderServiceTests.testDeepLinkTargetsCorrectCardOnRoundChange`） |

---

## 阶段间总体依赖图

```text
docs/API_CONTRACT.md ─┬─→ schema/ ─┬─→ 服务端统一模型（阶段一）
                       └────────────┴─→ iOS Domain 层模型（阶段二）

阶段一（发布流程 + 来源证据）──→ 阶段二（LiveRepository 消费已发布数据）──→ 阶段三（变更记录 + 提醒依赖阶段二的深链与数据模型）

docs/SOURCES.md（阶段一）──→ 各解析适配器（阶段一）
server/tests/fixtures/snapshots/*.html（已完成）──→ 各解析适配器的 pytest 用例（阶段一）
```
