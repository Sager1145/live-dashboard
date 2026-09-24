# 代码级修复计划：日期↔场馆、周边、图片、出演卡片、适用场次

执行者按本文顺序改代码并跑文末测试。不要扩大范围。不要用 App 里已经存过的字段值去填一次成功抓取的结果。

## 结论（最近提交）

工作区干净。最后一次有意义的代码是 `e97f114`（2026-09-23）。其后的提交只动 Finder 元数据。

| 用户问题 | 最近提交有没有修完 |
|---|---|
| 选日期必须对上该日场馆 | 没有。`244f8b6` 只加了城市名提示。`parseCombinedSchedules` 在只有一个场馆片段时丢掉日期映射，再把整页场馆或缓存场馆写到每一天。 |
| 周边信息显示不对 | 没有。`d83ad0d` 解析了 campaign / product / session，但每条 `scope` 都是 `.unconfirmed`，商品页把它们放进「适用场次待确认」，购买动作关闭。 |
| 周边页显示全部图片 | 没有。抓取可以有多张 `mediaAssetIDs`。`GoodsView` 只画第一张，其余藏在「查看全部 N 张图片」。 |
| 出演卡片分行，不要堆在一起 | 没有。出演是一条用「、」拼起来的 `Text`。`FlowLayout` 只用于票务徽章。 |
| 「适用场次待确认」大量误报 | 没有。多场次时票务默认 `.unconfirmed`，只有标题含 `全公演` / `通し` / `全日程`、`DAY n のみ`、或单独一个日期才会确认。周边、周边图、座席图永远是 `.unconfirmed`。 |
| 抓取不能依赖 App 已存信息 | 没有。成功抓到 HTML 后，空段落仍回填缓存的场次、场馆、开场时间、出演、票轮、周边、媒体。规格 `docs/spec/03-extraction-rules.md`「抓取失败」只允许**请求失败**时保留上次确认值。 |

iOS 详情页走 `ios/Sources/LiveIngestionCore/OfficialEventScraper.swift`。`server/src/ingestion/adapters/` 只解析当次 HTML，但 `server/src/ingestion-worker.ts` 的 `proposeSnapshot` 会把已发布 bundle 铺进新提案。两条都要改。

## 不变量

1. 身份可以复用：URL / `p` / `_id` → `event.id`；同一日期+dayLabel 复用 `performance.id`；同一 canonical URL 复用 media / goods id。这不是字段值。
2. 一次**成功**的详情抓取，场馆、开场、开演、出演、字幕、stop、票轮、福利、周边、商品、场次、媒体、适用场次，只来自这次 HTML。解析结果为空就写空数组或空字符串，不回填 `cached`。
3. **请求失败**（网络错误、非 2xx、空 body）才保留整份上次 bundle，并保持 `sourceHealth = .stale`。成功响应里某个段落缺失，不算抓取失败。
4. 适用场次只在页面文字（标题或该记录所在区块正文）写明范围，或该页只有一场时，才写成 `.performances`。没有写明的多场记录保持 `.unconfirmed`。禁止把「没写 Day2」当成「等于 Day1」。
5. 不要改 `PerformanceScopeResolver`：`.unconfirmed` 继续单独成桶，不并进当前场次。修的是写入 scope 的地方，不是把未确认偷偷显示成已确认。
6. 不要改仪表盘日期筛选（`DashboardStore` 用 `firstLocalDate`）。本次只修详情里选中的场次。

## 任务 1 — 日期和场馆按本次页面配对

文件：`ios/Sources/LiveIngestionCore/OfficialEventScraper.swift`

### 1.1 `parseCombinedSchedules`（约 763–816 行）

现在的错误：

- 多个日期正则与 `distinctDates` 数量必须相等才建映射。同一天两场（昼/夜）会让 match 数大于日期数，映射被跳过。
- `Set(venuesByDate.values).count < 2` 时清空映射，于是单场馆或多日期同一馆的页面丢失配对。
- 映射为空时 `venueFromOverview(raw)` 把**整段最后一个** `■会場` 贴到每个日期。

改成：

- 对每个日期 match，切片从该 match 起到下一个日期 match。场馆取这个切片里的 `venueFromOverview`。若切片里没有，再看该 match **之前、上一个日期之后**的前缀（场馆写在日期前面的版式）。
- 用切片里 `parseSchedules` 得到的 `localDate` 做 key，不要用 `distinctDates[index]` 去对齐另一条列表。
- 保留只有一个场馆值的映射。禁止 `count < 2` 时清空。
- 某个日期已经有自己的场馆时，禁止再用整段 `venueFromOverview(raw)` 覆盖其他日期。只有**所有**日期都没有切片场馆时，才允许整段一个场馆作为共享场馆。

### 1.2 `scopedVenue`（约 2617–2630 行）

城市对不上时现在 `return ""`。调用方 `item.venue ?? associatedVenue` 不会跳过空字符串，共享场馆被挡掉，UI 变成「会场尚未获取」。

对不上时 `return nil`。`venues.count <= 1` 时也返回 `nil`（保持现状，交给后面的共享场馆）。

### 1.3 `loveLiveStopVenues`（约 883–919 行）

现在少于两个不同场馆就 `return [:]`。改成：每个 `＜站名＞` 区块里解析出的日期都写入该区块的场馆，哪怕全巡演只有一个馆。区块没有场馆行则跳过该区块，不要把别的站的馆写进来。

`loveLiveStopDates` 已有站名。在 `parsedPerformances` 里，`stopID` 不要只抄 `prior?.stopID`。若本次 overview 有该日期的站名，用站名生成稳定 id：`stableID(prefix: "\(eventID)-stop", seed: stopName)`，并在 bundle 的 `stops` 里放对应 `Stop`（名称=站名）。没有站名则 `stopID = nil`。不要从 `cached?.stops` 复制。

### 1.4 `resolvedVenue`（约 529–554 行）

删除对 `prior?.venueName`、`prior?.venueCity`、`prior?.doorsAt`、`prior?.startAt`、`prior?.subtitle`、`prior?.editionID` 的回填。

```text
venueName = item.venue（非空）
  ?? scopedVenue(...)（非空）
  ?? loveLiveStopVenues[date]
  ?? 仅当本次 schedules 里没有任何一个非空 venue 时，使用 cleanedVenue 的共享场馆
  ?? ""
```

`hasDistinctScheduleVenues` 为 true 时，共享 `venue` 和任何 prior 场馆都不得写入缺少场馆的那一天。该天 `venueName` 留空。

`doorsAt` / `startAt` 只用本次 `reinterpretJapanWallTime`。解析不到就是 `nil`。
`subtitle` 只用 `item.subtitle`。
`venueCity` 只用本次 `venueCity(resolvedVenue)`，空则用本次 `stopCity(loveLiveStopByDate[date])`，再空则 `""`。

`PerformanceSelector.shortLabel` 在场馆集合 `count > 1` 时才把 `venueName` 放进菜单。配对修好后这个条件会生效。不要为了单馆页面强行改菜单。

## 任务 2 — 成功抓取不再回填已存字段

同一文件，`refresh` / `parseDetail` 路径（约 170–240、565–673、2495–2513、2895–2921 行）。

### 2.1 成功解析

删除这些回填（成功拿到详情 HTML 时）：

- `performances = parsedPerformances.isEmpty ? oldPerformances : parsedPerformances` → 永远用 `parsedPerformances`。空就是没有场次。
- `baseTiers`、`rounds`、`ticketBenefits`、`mediaAssets`、`goodsCampaigns`、`products`、`goodsSessions`、`streamOffers`、`sourceText` 的 `isEmpty ? cached : parsed`。
- `stops`、`ticketOffers`、`notices`、`editions` 从 `cached` 整表复制。本次没解析到就写 `[]`。
- `resolvedPerformerNames` 的 `priorPerformers` 参数。删掉这个参数和 `associatedPerformers.isEmpty ? priorPerformers` 分支。页面没写出演就是 `[]`。
- `mergeMedia` / `mergeGoods` 保留「这次页面没出现的旧 campaign / 旧图」。成功解析后集合以本次结果为准。id 仍可按 canonical URL / 标题从 cached **只读 id**，不读旧的 scope、venue、文案、图片列表。

`retainedStaleCache` 在成功响应上改为 false。`sourceHealth = .healthy`。

### 2.2 请求失败

`OfficialEventScraper.swift` 约 208–216 行：详情请求失败时，可以 append 上次 bundle，这是规格允许的「上次确认」。不要在失败路径上改字段。

约 170–185 行：索引漏掉某条时，可以用缓存 bundle 发现「还要去抓这个 URL」（身份）。随后必须抓详情页。抓成功后按 2.1 只信 HTML。不要用缓存的 `officialTitle` / `groups` 覆盖页面标题；页面没有标题时标题留空或用候选列表标题，不要用旧 bundle 的票务和场馆。

### 2.3 服务器

`server/src/ingestion-worker.ts` `proposeSnapshot`（约 465–583 行）：

- 新提案的 event / performances / tickets / goods / media 只含本次 snapshot candidates。
- 禁止 `...(existing?.bundle ?? {})` 和 `...(existing?.bundle.event ?? {})` 把旧票务、旧周边、旧场馆留在新提案里。
- `event.id` 与 `stableIdentity` 可以继续对上已有行。
- 页面没写 `eventType` / `status` 时用 `"unknown"` / `"scheduled"` 仅当本次候选没有状态；不要从旧 bundle 继承票价和商品。

`server/src/proposal-details.ts` `mergeSnapshotDetails`：禁止 `{ ...stored, ...extracted }`。写入本次 extracted 记录。stored 里多出来的 key 丢掉。

## 任务 3 — 适用场次按页面文字确认

文件：`OfficialEventScraper.swift` 的 `explicitScope`（约 2925–2957 行）和所有写死 `scope: .unconfirmed` 的构造点。

### 3.1 扩展 `explicitScope`

签名改为：

```swift
static func explicitScope(text: String, performances: [Performance]) -> Scope?
```

`resolvedScope` 把 **heading + 该记录区块正文** 拼成 `text` 传入（中间一个换行）。不要只传 `officialName`。

按顺序，先命中先返回：

1. 文本含 `全公演`、`通し`、`全日程`、`各公演`、`全日`、`両日共通`：`.performances(performanceIDs: 全部 id)`。performances 为空则 `nil`。
2. 文本含 `両日` 且 `performances.count == 2`：全部 id。多于两场则不命中，继续往下。
3. `DAY\s*(\d+)\s*のみ`，或单独的范围标记 `DAY\s*(\d+)` / `Day\.(\d+)` 出现在标题或「対象」行（不要在整页脚注里扫）。匹配 `performanceMatchesDay`。
4. 已有的「年月日」规则，对拼接后的 text 生效。多个日期就收集多个 id。一个日期对不上本次 performances 则不要猜年份以外的场。
5. `＜...公演＞` / 站名行：若 performances 的 `stopID` 或 `venueCity` 对得上该站，返回这些 id。对不上则 `nil`。
6. 没有命中返回 `nil`。调用方再用 fallback。

`ticketScope` fallback 保持：`performances.count == 1` 时用那一场的 id，否则 `.unconfirmed`。这不是猜测，一页一场不能指别的日子。

### 3.2 应用到这些记录

构造时先放 `.unconfirmed`，在列表组装完、performances 已知之后，逐条 `replacingScope(resolvedScope(..., text: heading + "\n" + sectionBody, fallback: ticketScope))`。

必须跑到：

- BanG Dream 与 Love Live 的 `TicketRound`（已有 `resolvedScope`，把正文传进去）
- `TicketBenefit`（现在只用 `ticketScope`，多场次永远未确认）
- `GoodsCampaign`（约 2205、2223、2261 行，现在写死 `.unconfirmed`）
- goods 图片 `MediaAsset.scope`（约 2166 行）与座席/主视觉里**本页专属**的图。场馆通用座位图保持 `.unconfirmed`（规格 `venue_generic`）。
- `StreamOffer`：fallback 改为 `ticketScope`，不要永远 `.unconfirmed`。Love Live 按日配信如果正文或标题有 Day / 日期，走 `explicitScope`。

`structuredGoods` 已复制 `campaign.scope`，campaign 确认后 session 会跟着确认。

商品页效果：scope 含当前场次的周边进入「现场／会场领取」或「官方通贩」，`actionsAllowed: true`。只有页面真没写范围的多场记录留在「适用场次待确认的周边资料」。

### 3.3 不要改的测试语义

`OfficialAuditRegressionTests` 里「一般発売 标题没有任何日期则保持 unconfirmed」仍然成立。如果该轮**正文**写了日期或全公演，测试应改成期望 `.performances`。先读该 fixture 的 HTML 再改断言，不要为了通过测试把正文规则删掉。

## 任务 4 — 周边页显示全部图片和已解析字段

文件：`ios/Sources/LiveDashboardKit/Features/LiveDetail/Goods/GoodsView.swift` 约 231–242 行。

删掉 `assets.first` + `DisclosureGroup`。对 `mediaAssets(for: campaign)` 的**每一个** asset：

```swift
ForEach(assets) { asset in
    OfficialMediaView(asset: asset, fitsWidth: true)
}
```

纵向排列，每张全宽，保留现有点击放大。不要只显示第一张。

子 campaign（事前/事后）现在 `mediaAssetIDs: []`（约 2229 行）。目录 campaign 已经带全图。子轮次卡片不复制整库图片，避免每一轮重复刷全套海报。目录卡片必须带全套 `mediaAssetIDs`。

价格、购买限制、配送、付款、链接已经在 `campaignCard` 里。它们不显示，是因为未确认桶把 `actionsAllowed` 设成 false，以及 product 的 `amount` 经常是 nil（`structuredGoods` 用栏目标题当商品名）。本次：

- scope 修好后，已确认周边走正常卡片，购买链接可用。
- `structuredGoods`：正文里 `名称 + 金额円` 的行要变成 `Product`，`amount` 用该金额，名字用该行的商品名，不要只用栏目标题且 `amount: nil`。没有金额的行不要编价格；UI 继续显示「价格待核对」。
- 同一商品名的多个金额不要合并成一个。

`extractImages` / `isDirectImageURL`：除了 `.jpg/.png/.webp/.gif/.avif`，把 Love Live `image.php?img_path=` 这类官方图片端点当图片。`canonicalURL` 必须保留不同的 `img_path`，不能折成同一个 URL。

## 任务 5 — 出演者每人一张芯片，自动换行

文件：`ios/Sources/LiveDashboardKit/Features/LiveDetail/Overview/OverviewView.swift` `PerformersCard`（约 188–215 行）。

现在 `OfficialTextList(..., separator: "、")` 把所有名字合成一个 `Text`，超过 8 人再折进 Disclosure。用户看到的是挤在一起，不是分行的卡片。

改成：每个人名一个芯片，全部显示，用已有 `FlowLayout`（`ios/Sources/LiveDashboardKit/Features/LiveDetail/../Shared/FlowLayout.swift`，水平/垂直间距 6）。不要用 `HStack`、不要用 `ZStack`、不要再用「另外 N 位」折叠。

每个芯片：

- `OfficialText(name, cardKey:eventID:)`
- `.font(.subheadline)`
- padding horizontal 10、vertical 6
- `RoundedRectangle` 描边或 `secondary` 的淡底，和票务徽章视觉同级
- 一个名字一行内能排开；`FlowLayout` 在超出卡片宽度时换到下一行
- accessibility 每个芯片是一个元素，label 为出演者名字

空列表仍显示「出演信息尚未获取或待核验」。

数据侧已经按日切开的 `loveLivePerformers` / `resolvedPerformerNames` 不要改成「把所有人贴到每一天」。任务 2 删掉 prior 回填后，某天页面没写人就保持空。

`notedPerformers` 里把 `夢限大みゅーたいぷ` 改写成 `千石ユノ（夢限大みゅーたいぷ）` 的硬编码删掉。页面写什么名字就保存什么名字。

## 测试

在 `ios/` 下：

```bash
swift test --filter 'OfficialEventScraperTests|OfficialAuditRegressionTests|OfficialFieldOrganizationTests|OverviewCardsTests|MediaPresentationTests|ContractTests'
```

需要新增或改写的用例（放在现有 scraper 测试文件，用字符串 HTML，不要联网）：

1. 两个日期，各自后面跟不同 `■会場`。选中第一天的 `venueName` 是第一馆，第二天是第二馆。预先塞一个带错误场馆的 cached bundle，刷新后场馆仍是 HTML 里的，不是缓存。
2. 场馆行写在日期前面。日期对上该馆，而不是上一个日期。
3. 只有一个场馆、多个日期，且页面没有把馆拆开。每个日期的 `venueName` 相同且等于该馆。缓存里的另一馆不得出现。
4. `scopedVenue` 城市不匹配时，不把场馆写成空字符串挡住共享场馆。
5. 成功 HTML 里没有票轮、没有周边。结果的 `ticketRounds` 与 `goodsCampaigns` 为空，即使 cached 里有。
6. 详情请求抛错或非成功。bundle 仍是上次那份（失败路径）。
7. 周边区块正文含 `全公演` 或仅一场。`GoodsCampaign.scope` 为 `.performances` 且包含该场 id。多场且正文没有任何日期/全公演/`DAY n`。scope 仍是 `.unconfirmed`。
8. 票轮标题是 `一般発売`、正文没有日期。scope 仍是 `.unconfirmed`（保住现有回归）。
9. 票轮标题或正文含一个对得上的 `M月D日`。scope 只含该日 performances。
10. 商品行 `T シャツ：3,500円` 产生 product，`amount` 为 3500，不是 nil。
11. 一个 goods 区块三张不同图片 URL。campaign.`mediaAssetIDs.count == 3`。`image.php?img_path=a` 与 `img_path=b` 是两条 asset。

UI：`OverviewCardsTests` 若快照了出演字符串，改成断言每个名字都在，且不再依赖「、」拼接。没有快照测试就加一个纯函数不必要；芯片是 View，用现有 UI 测试模式。若没有 View 测试基建，不要新造快照框架。改完用代码审查确认 `PerformersCard` 使用 `FlowLayout` 且 `GoodsView` 对全部 asset `ForEach`。

服务器：

```bash
cd server && npx vitest run test/proposal-details.test.ts test/publisher.test.ts test/ingestion-adapters.test.ts
```

给 `mergeSnapshotDetails` / `proposeSnapshot` 加一条：旧 bundle 有票价，新 snapshot 没有票价候选，提案里不得还带着旧票价。

## 完成标准

- 选中一个日期，时间与会场卡片的场馆是该日期在本次官方 HTML 里的场馆。另一天换馆时，菜单或卡片跟着变。
- 页面写了适用全部场次或具体日期的周边，出现在对应分区，而不是「适用场次待确认」。页面没写的多场记录仍在待确认桶。
- 周边卡片上，该 campaign 的每一张图都直接可见。
- 出演者每人一块，宽度不够就换行，不合成一条、不叠在同一个 Text 里。
- 删掉 App 里旧 bundle 再抓一次，字段与不删时一致（id 可以相同）。只有请求失败才允许看到旧值。
