# 验收场景

20 份样本位于 [`fixtures/samples/`](../../fixtures/samples/)，来源清单为 [`fixtures/sources-manifest.json`](../../fixtures/sources-manifest.json)。每份样本内含 `acceptance[]`，下面是跨样本的第一批回归场景。

| # | 验收场景 | 样本 | 必须满足 |
|---|---|---|---|
| A1 | 同一公演三天、三套受付 | BD01 | 切 Day 后截止时间、入口、特典一起变化；三个 Day URL 不生成三张首页卡 |
| A2 | 原公演与追加版本 | BD02 | 神户版不覆盖原日期，不继承横滨版暖场名单、限制视野席、座位图、票价 |
| A3 | 两日各有昼夜场 | LL02 | 四个独立 `performanceId`；只在 10/11 出演者不出现在 10/10 名单 |
| A4 | 不同 CD 对应不同场次先行 | LL06 | 专辑先行只绑定三站 Day1；Fan Disc 先行只绑定东京 Day2 |
| A5 | 同一艺人售票列表出现不同届公演 | LL07、LL08 | 2nd 与 3rd 的受付、状态不混合 |
| A6 | 多 Stage、多站物贩与发货 | LL10 | Stage、城市、Day、商品批次独立；受注商品发货可与普通商品不同 |
| A7 | 物贩消费门槛与票价并存 | BD10 | ¥2,000 落入 `purchaseBonus.threshold`，不进入任何 `TicketType.price` |
| A8 | 同价但不同权益的票 | BD01 | 3DAYS 通票与单日 Premium Seat 各为独立 `TicketType` |
| A9 | 网站抓取失败 | 全部 | 字段为 `Unknown` 时保留 `lastConfirmedValue`，不显示“官方未公布” |
| A10 | 公演结束但其他期限有效 | LL08、LL01 | 现场受付折叠，配信回放、After Pamphlet 预订与发货仍可见 |
| A11 | 现场售罄与配信、商品独立 | BD03 | 现场 `sold_out` 不改变 `Stream` 与 `Product.stockStatus` |
| A12 | 跨境站点 | BD07 | 台北站显示 TWD 与当地入口，不显示日本站日元票价 |
| A13 | 配信地区限制不污染现场票 | BD08 | `regionRestriction` 只在 `Stream` 上 |
| A14 | 混合活动巡回 | BD09 | Live 筛选只保留 `performanceType = live`；免费部分直播不摘要成整场免费或有回放 |
| A15 | 资料稀疏 | BD04 | 只有已核到的日期、场馆、先行开始时间；其余为 `Unknown`，不虚构 |
| A16 | 同名实体去重 | BD06、LL10 | 专辑／纪念 Live／周年 Tour，电影／Live／Blu-ray 各自独立 ID 并互相关联 |
| A17 | 优惠票不作最低价 | LL04 | U20 ¥6,500 带 `eligibility`，摘要显示普通票 ¥13,000 |
| A18 | 相邻日期不同公演 | LL04、LL05 | `p=LLDream106` 与 `p=LLDream103` 独立 `eventId`；封入先行不跨公演 |
| A19 | 语义参数保留 | LL07 | `_id=3rdLIVE` 保存在 `identityParams` |
| A20 | 场馆别名 | LL09 | 别名合并到同一 `Stop`，不生成重复场馆 |

## 通用断言

对每一份样本：

1. 通过 `schema/live-dashboard.schema.json` 校验。
2. 每个 `salesRound` / `stream` / `merchBatch` / `image` 的 `appliesTo.scope` 为 `explicit` 或带 `evidenceIds` 的 `all`；不存在无范围的可提醒字段。
3. 所有 `evidence[].sourceUrl` 出现在 `event.sources[]`、`stops[].sources[]` 或 `performances[].sources[]` 之一。
4. 任何 `Money` 都带 `currency`；`purchaseBonus.threshold` 的金额不出现在同一样本任一 `TicketType.price`。
5. `event.lifecycle = ended` 的样本至少保留一个仍有 `closesAt` 在 `asOf` 之后、或为 `Unknown` 的配信／物贩对象（LL08、LL01 适用）。
