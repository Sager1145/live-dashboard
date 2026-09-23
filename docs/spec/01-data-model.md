# 数据模型

对应 schema：[`schema/live-dashboard.schema.json`](../../schema/live-dashboard.schema.json)。

## 基本原则

1. **首页可以统一成一种 Live 卡片，但后台不能统一成“一场 Live＝一个网址＝一个日期＝一个售票链接”。**
2. 公演、票务、配信、物贩是四条不同的生命周期。`event.lifecycle = ended` 不关闭其他三条。
3. 未知不是 `null`。每个可缺失字段允许取值，或取 `Unknown` 对象，其 `state` 为：

   | state | 含义 | UI 行为 |
   |---|---|---|
   | `not_fetched` | 尚未抓取 | 显示“资料尚未核验”，不显示“官方未公布” |
   | `parse_failed` | 抓到页面但解析失败 | 同上，并保留 `lastConfirmedValue` |
   | `not_confirmed` | 已抓到、待人工或二次核验 | 显示值，标记待核验，不进入提醒 |
   | `officially_tba` | 官方明确写明“後日発表” | 显示“官方待公布” |
   | `not_applicable` | 对此对象不适用 | 隐藏对应卡片 |

4. 每个事实字段至少绑定一条 `Evidence`。证据保存原文、来源 URL、区块、适用范围、发布时间、抓取时间、核验状态。

## 实体关系

```text
Event ─┬─ Edition*  （原公演 / 追加版 / Stage）
       ├─ Stop*     （巡演站点、城市、场馆、时区、币种）
       └─ Performance*  （日期、Day、昼夜、开场/开演、出演者）
              ↑ appliesTo
TicketType* / SalesRound* / Stream* / MerchBatch* ─ Product* / Image* / Notice*
```

所有票务、图片、物贩对象都通过 `Applicability` 声明适用范围：

- `scope: explicit` 必须列出 `performanceIds` / `stopIds` / `editionIds`。
- `scope: all` 必须附 `evidenceIds`，证明官方写明“全公演共通”。
- `scope: unknown` 表示尚未确认适用范围，UI 不得把它显示在任何具体场次下。

## 共享选择状态

iOS 详情页四个 Tab 共用一组选择：

```text
eventID → editionID（有则用）→ stopID（有则用）→ performanceID
```

进入详情时一次获取整个 bundle，切换 Day 只在本地按 `appliesTo` 过滤，避免“顶部已是 Day2，商品表仍是 Day1”。

## 时间字段语义

不能只有 `startDate` / `endDate`。至少区分：

| 字段 | 所在对象 |
|---|---|
| `date`、`doorsAt`、`startsAt` | Performance |
| `applicationWindow`、`resultsAt`、`paymentWindow` | SalesRound |
| `salesWindow`、`viewingWindow` | Stream |
| `salesWindow`、`venueHours`、`shippingEstimate` | MerchBatch |
| `shippingEstimate` | Product（受注商品可与批次不同） |
| `publishedAt`、`observedAt` | Evidence / Image / Notice |

所有 `DateTime` 带时区偏移；`LocalTime` 配合所属 Stop / Performance 的 `timeZone` 解释。

## 金额语义

`Money` 必带币种。以下金额不是票价，各自有独立位置：

- 物贩特典抽选消费门槛 → `MerchBatch.purchaseBonus.threshold`
- 商品价格 → `Product.price`
- 配信票价 → `Stream.price`

带 `eligibility` 的票种（U20 等）不得用于“¥X 起”摘要。

## 身份与去重

- Love Live! 详情页身份来自查询参数 `p` 或 `_id`，保存在 `Source.identityParams`，URL 清理时不得丢弃。
- 同名实体（专辑、纪念 Live、周年 Tour；电影、Live、Blu-ray）用 `Event.relatedEntities` 关联，各自独立 ID。
- 场馆别名放入 `Stop.venueAliases`，不生成新场馆。
- 一个公演的多个详情 URL（13th 的三个 Day 页）绑定到同一 `eventId` 下的不同 `performanceId`，不生成多张首页卡。
