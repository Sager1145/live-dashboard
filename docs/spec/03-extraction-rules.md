# 提取规则

## 处理顺序

```text
来源网址 → 页面类型 → 公演身份 → 主内容区块 → 版本／站点／场次范围 → 事实字段 → 原文证据 → 校验与发布
```

不能反过来先抓所有日期和金额再猜归属。每个字段在写入前必须已知 `Applicability`。

## 六类解析适配器

对应 `Source.adapter` 枚举。

| 适配器 | 处理内容 | 样本 |
|---|---|---|
| `event_list` | 发现标题、详情 URL、日期摘要、分类；不直接生成详情 | 全部 |
| `bangdream_event` | 总专题、Day 页面、巡演分站 | BD01、BD07、BD08 |
| `lovelive_detail` | 按 `p` / `_id` 识别身份及内容分区 | LL01–LL10 |
| `official_news` | 更正、封入资格、追加出演、商品通知 | LL06、LL08、LL10 |
| `ticket_platform` | 每场、每轮受付、平台状态、申请要求 | BD01、LL07 |
| `store_media` | 批次、商品、价格、库存、图片、发货 | BD03、LL01、LL03、LL08、LL10 |
| `venue_schedule` | 交叉核对日期与时间 | BD03 |
| `performer_site` | 出演者个人官网／事务所日程 | LL01、LL02 |

适配器共用日期、金额、链接、证据结构；页面分区和公演关系各自处理。正式开发前先保存实际 HTML 样本再定选择器，本仓库不提供任何声称已验证的 CSS 选择器。

## 身份规则

- Love Live! 的 `live_detail.php?p=…` 与 `live_detail.php?_id=…` 中的参数是公演身份，写入 `Source.identityParams`，清理 URL 时保留。
- BanG Dream! 总专题页建立 `eventId`，各 Day 页面建立 `performanceId`；售票平台每个受付绑定到具体场次。
- 追加版本（“神戸再景編”、台北追加公演）建立 `editionId` 或 `stopId`，不靠标题相似度合并正文。
- 同一售票平台艺人索引可能同时列出多届公演（Bluebird 2nd / 3rd），先按公演标题＋日期＋场馆划分区块，再提取其中受付。

## 时间规则

- 配信日期范围（如“6 月 18—25 日”“到 6 月 21 日”）写入 `Stream.viewingWindow`，不生成现场场次。
- Blu-ray、CD 发售日写入 `relatedEntities`，不生成 `Performance`。
- 商品发货日写入 `MerchBatch` / `Product.shippingEstimate`，不进入公演日期。
- 未读到截止时间时保持 `Unknown`，不补成“开演前一天”。
- “前夜祭”是名称，不据此计算日期。
- 来源发布时间（`publishedAt`）与抓取时间（`observedAt`）分开保存。

## 金额规则

提取金额必须保留所在区块与相邻说明：

| 出现位置 | 落入字段 |
|---|---|
| チケット料金 | `TicketType.price` |
| 配信チケット | `Stream.price` |
| 商品价格 | `Product.price` |
| “○円以上お買い上げで抽選” | `MerchBatch.purchaseBonus.threshold` |

只用正则找所有“円”会产生错误的首页最低票价。

## 状态规则

分别保存，不能用一个 `isSoldOut` 控制全部：

```text
现场票状态（SalesRound.platformStatus）
配信票状态（Stream.salesWindow）
物贩批次状态（MerchBatch.status）
单件商品库存（Product.stockStatus）
```

平台标记“受付中”不等于每一种席种都有库存。

## 两类易错的共通内容

`Evidence.sectionKind` 用于区分：

| sectionKind | 含义 | 可否单独支撑可提醒字段 |
|---|---|---|
| `event_specific` | 本公演专属 | 可以 |
| `batch_specific` | 本批次专属 | 可以 |
| `product_specific` | 本商品专属 | 可以 |
| `store_global_terms` | 店铺通用条款（如页脚“会场领取”一般说明） | 不可以 |
| `store_cross_promo` | 商店“当前销售受付”区域列出的其他公演 | 不可以 |
| `venue_generic` | 场馆通用座位图 | 不可以 |
| `search_index_snippet` | 搜索索引片段 | 只作发现 |

## 出演者规则

分别保存 `onStage`、`openingAct`、`onScreen`、`guests`。只从本场公告提取，不从团体成员总表自动生成；一日的嘉宾不复制到另一日或另一版本。

## 图片规则

- 保存 `purpose`、`url`、`thumbnailUrl`、`sourceUrl`、`caption`、`appliesTo`、`contentFingerprint`。
- 同 URL 内容被替换时通过 `contentFingerprint` 变化发现，生成 `Notice(kind=new_image)`。
- 有文字优先用文字。只有图片时才做图中文字识别；识别出的截止时间、金额、限购、入场条件核验后才进入可提醒字段，原图始终保留。

## 抓取失败

抓取失败保留上次已确认数据于 `Unknown.lastConfirmedValue` / `lastConfirmedAt`，UI 显示“上次确认”，不伪装成“官方未公布”。
