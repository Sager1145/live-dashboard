> 历史设计记录：本文保留原型阶段内容。当前实现与验收以 [完整计划](FULL_IMPLEMENTATION_PLAN.md)、[API 契约](API_CONTRACT.md) 和 [验收报告](IMPLEMENTATION_STATUS.md) 为准。当前范围只接受显式 Performance ID 集合或 unconfirmed；不再使用动态 wholeEvent／stop 范围。

# 数据模型说明

本文档是 `docs/API_CONTRACT.md`（`LiveEventBundle` JSON 契约 v1）中各模型的叙述性说明：每个模型的用途、关键字段、以及必须遵守的不变量。字段的具体类型与可选性以 `API_CONTRACT.md` 为准，本文档不重复列出完整 JSON 结构。

## 全局不变量

在阅读各模型之前，以下五条规则适用于整个数据模型，任何单一模型的设计都不能违反它们：

1. **稳定 ID 绝不从日期生成。** 公演、场次等实体的 `id` 是与业务身份绑定的稳定字符串。公演延期后只更新日期字段，`id` 不变，从而保留用户的关注状态、提醒配置和个人记录。
2. **适用范围（`Scope`）必须显式表达，不能靠隐含推断。** 任何与「哪一天／哪些场次」相关的记录都携带显式 `Scope`；「没有写 Day2」不会被自动解释为「与 Day1 相同」，也不会被转换成 `wholeEvent`——无法确定时输出 `unconfirmed`。
3. **「没有写」≠「适用于整场公演」。** 对应上一条的反面表述：缺失的每日信息必须落在 `unconfirmed`（适用范围待确认），不能被默认为 `wholeEvent`（整项公演共通）。
4. **数据状态（`DataStatus`）有五个值，不只是「有／无」二元状态。** `confirmed`（已确认）、`officiallyTBA`（官方明确待公布）、`notFetched`（尚未获取）、`parseFailed`（解析失败）、`notApplicable`（不适用）。抓取或解析失败必须标记为 `parseFailed` 并保留上一次已确认的数据，绝不能显示为 `officiallyTBA`——「网站抓取失败」不是「官方尚未公布」。
5. **每个重要字段都要能回到官方来源，且三个时间戳互不相同。** `SourceEvidence` 记录来源发布时间（`sourcePublishedAt`，来源自己何时发布该内容）、最后成功核对时间（`verifiedAt`，采集器何时确认该内容仍然有效）、以及 App 端的下载时间（由 App 同步时刻决定，不在本 JSON 内）。三者不能混用；重新抓到一篇旧公告不能因为「今天抓到」就覆盖更新的信息，来源优先级需结合具体字段、公告内容和发布时间判断。

---

## LiveEvent（公演）

**用途**：代表一项官方公演或巡演的顶层身份，是首页一张卡片对应的实体。

**关键字段**：`id`（稳定 ID）、`officialTitle`（官方全名）、`franchise`（企划：`bangdream` / `lovelive`）、`groups`（参与团体）、`eventType`（`live` / `fanMeeting` / `screening` / `other`）、`status`（`scheduled` / `postponed` / `cancelled` / `finished`）、`primarySourceURL`、`timeZone`（主办方所在地时区）。

**不变量**：
- `id` 不由日期派生（全局规则 1）。
- 不能仅因会场相同或名称相似就合并两项官方上独立的公演。
- 取消、延期等重大状态属于 `LiveEvent.status`，在界面上固定显示在标题区域，不依赖某张可能被隐藏的普通卡片。

## LiveStop（巡演站点）

**用途**：巡演中的一个城市／会场站点，可选——非巡演公演没有 `LiveStop` 记录。

**关键字段**：`id`、`eventID`（所属公演）、`name`（站点名称）、`order`（显示顺序）。

**不变量**：
- 站点是 `Scope` 的三种具体取值之一（`{ "kind": "stop", "stopID": "…" }`），使物贩、票务等记录能够限定在「这一站」而不误用到其他站点。

## Performance（场次）

**用途**：公演的具体日期与场次——这是选择器最终选中的粒度，而不是「日期」。

**关键字段**：`id`、`eventID`、`stopID`（可为 `null`）、`dayLabel`（如 `DAY1`）、`subtitle`（如「昼公演」，可为 `null`）、`localDate`、`doorsAt`／`startAt`（未公布时为 `null`，不用零点代替）、`venueName`、`venueCity`、`performers`（当场出演者）、`order`。

**不变量**：
- 同一天可能有多场（昼／夜公演），`Performance` 而非 `Date` 才是选择单位，否则昼夜场信息会互相混用。
- `id` 不由日期生成（全局规则 1），保证公演延期后关注和提醒不丢失。
- 四个详情 Tab（概要／售票／座位／周边）共享同一个 `selectedPerformanceID`；切换场次后，所有关联记录按 `Scope` 重新匹配。

## TicketTier（票种）

**用途**：定义一种票的价格与性质，供 `TicketOffer` 引用。

**关键字段**：`id`、`eventID`、`name`、`priceJPY`（可为 `null`）、`priceKind`（`full` 完整票价 / `upgradeDifference` 升级差额 / `streaming` 直播票 / `under20` U20 票）、`includes`（特典说明）、`feeNote`、`taxNote`。

**不变量**：
- `priceKind` 必须明确区分完整票价与升级差额：「升级费用」不等于「完整票价」。首页「最低价」不应把 U20、直播票或升级差额算入普通现场票价格。

## TicketRound（受付轮次）

**用途**：每一轮售票／申请受付作为独立记录，而不是把整场公演压缩成一个售票链接。

**关键字段**：`id`、`eventID`、`officialName`（如「先行抽选」「一般发售」「升级受付」）、`kind`（`lottery` / `firstComeFirstServed` / `resale` / `upgrade` / `other`）、`scope`（`Scope`）、`applyStartAt`／`applyEndAt`／`resultAt`／`paymentDeadlineAt`、`eligibility`（资格前提）、`announcementURL`／`applyURL`／`overseasURL`、`officialStatus`（官方原文状态）、`status`（`DataStatus`）、`links`（官方页面上其它具名链接，`OfficialLink[]`，默认 `[]`）。

结构化补充字段（均为可选，默认 `nil` / `[]`）：`applyWindowText`（受付期間／受付時間／申込期間／発売日／発売日時 的原文，多行用 `\n` 连接）、`resultText`（当落発表／当選発表／抽選結果 原文）、`paymentStartAt`（入金期間起始时间，仅当原文写明区间起止两端时才有值）、`paymentWindowText`（入金期間／支払期間／支払期限 原文）、`quantityLimit`（枚数制限 原文）、`lotteryProducts`（抽选用商品／封入申込券对应的商品名数组，逐条原文，默认 `[]`）、`applicationTarget`（★申込対象 原文，已去掉外层的 ＜＞）、`notes`（`TicketNote[]`，默认 `[]`，见下文）。

**TicketNote（重要提示）**：`kind`（`faceRecognition` 顔認証 / `companionRegistration` 同行者登録 / `identityCheck` 本人確認 / `smartTicketOnly` スマチケのみ / `creditCardOnly` クレジットカード決済のみ / `membershipRequired` 会員登録必要 / `other`）、`text`（原文句子，可能多行）、`links`（该提示相关的官方引导链接，`OfficialLink[]`，默认 `[]`）。

**OfficialLink.role**：`application`（真正的申请/受付入口）、`overseasApplication`（海外申请入口，如 ib.* / KKTIX / Cityline）、`support`（票务服务商的客服／FAQ／会员／引导页面）、`product`（关联商品页，如封入申込券所属的专辑页）、`other`（其余）。分类由 `OfficialLink.classify(label:url:)` 统一计算，规则详见该方法实现，`role` 为可选字段，旧数据解码为 `nil`。

**不变量**：
- 每一轮受付是独立记录，旧轮次不会被新轮次覆盖；多轮可以同时存在，各自的时间、资格、价格关系互相独立。
- 「申请时间已开始」不等于「目前一定还有票」——`officialStatus` 与 `status` 分别保存官方原文状态和采集器推断状态，不混为一谈。
- `scope` 遵循全局规则 2／3：受付适用的场次范围必须显式给出，无法确认时为 `unconfirmed`。
- 只有官网明确写出的信息才会出现在这些字段中（没有 = `nil` / 空数组），链接分类只用于展示分组，不改变 `links` 的原文与顺序。

## TicketOffer（受付-票种-场次关联）

**用途**：把 `TicketRound`、`TicketTier`、`Performance` 三者关联起来，表达「这一轮、这个票种，适用于哪些场次、什么价格」。

**关键字段**：`id`、`roundID`、`tierID`、`performanceIDs`（适用场次列表）、`priceJPY`（该关联下的实际价格，可能与 `TicketTier.priceJPY` 不同，例如升级差额场景）。

**不变量**：
- 一个 `TicketRound` 可以对应多个 `TicketOffer`（不同票种、不同场次组合），价格关系（完整价 vs. 升级差额）在票种层已经区分，`TicketOffer.priceJPY` 承载该组合下的具体金额。

## TicketBenefit（グッズ付きチケット特典）

**用途**：官方页面在「料金」下方以「グッズ付きチケット特典」／「チケット特典」标题刊登的、随特定票种附赠的周边内容，以及现场领取方式。与 `TicketTier` 并列展示，不混入 `GoodsCampaign`。

**关键字段**：`id`、`eventID`、`officialName`（标题原文）、`scope`（`Scope`）、`tierIDs`（名称含「グッズ付」的票种 ID）、`detail`（特典内容原文，官方待公布时为 `nil`）、`notes`（※ 备注；官方写「後日公開」时保存该句原文）、`redemptionLocation`／`redemptionWindow`（「引換場所」「引換日時」原文）、`redemptionNote`（引换说明其余原文）、`mediaAssetIDs`（特典图片，`MediaAsset.kind = product`）、`status`（`DataStatus`）、`links`（`OfficialLink[]`）。

**不变量**：
- `status = officiallyTBA` 只表示官方明确写了「後日公開／未定」；页面完全没有该标题时不生成记录，由客户端根据「グッズ付」票种显示「官方尚未公布」占位。
- `detail` 有值时会复制到对应 `TicketTier.includes`（仅当 `includes` 原本为空）。
- 单场公演的 `scope` 为该场次；多场公演在未能确认前为 `unconfirmed`。

## GoodsCampaign（物贩批次）

**用途**：以「销售批次」建模周边商品的售卖／领取安排，而不是把整场公演的所有物贩信息合并成一条记录。

**关键字段**：`id`、`eventID`、`officialName`、`channel`（`online` 网上购买 / `venue` 现场购买）、`fulfillment`（`shipping` 邮寄 / `venuePickup` 会场领取）、`phase`（`pre` 事前 / `during` 会期 / `post` 事后）、`scope`（`Scope`）、`salesStartAt`／`salesEndAt`、`pickupWindow`、`shippingNote`、`location`、`requiresTicket`、`purchaseLimit`、`paymentMethods`、`url`、`mediaAssetIDs`、`status`（`DataStatus`）、`links`（官方页面上其它具名链接，`OfficialLink[]`，默认 `[]`）。

**不变量**：
- 渠道（`channel`）、履约方式（`fulfillment`）、销售阶段（`phase`）三个维度分开建模，「网上预订、当天会场领取」这类组合不会被强行塞进单一类别。
- 同一公演下可以有多个物贩批次（例如事前通贩批次与 After Pamphlet 批次），互不覆盖。
- `scope` 可以是整场公演共通，也可以限定到某一天（如 DAY1 专属通贩）；「没有写 Day2」不会被当成「与 Day1 相同」（全局规则 3）。
- 场贩时间可以早于公演日期，通贩时间也可以晚于公演结束；`salesStartAt`／`salesEndAt` 按销售批次自身的时间线记录，不强制套用开演日。

## MediaAsset（媒体资源）

**用途**：以正式数据的方式保存图片（主视觉、商品一览表、场贩说明图、物贩区域图、公演座位图、场馆通用座位图等）。

**关键字段**：`id`、`eventID`、`kind`（`keyVisual` / `goodsList` / `venueGoodsNotice` / `goodsAreaMap` / `eventSeatingMap` / `venueGenericSeatingMap`）、`originalURL`、`thumbnailURL`、`scope`（`Scope`）、`sourceURL`、`version`、`caption`。

**不变量**：
- 必须明确区分「本公演官方座位图」（`eventSeatingMap`）与「场馆通用座位图」（`venueGenericSeatingMap`）；后者不等于本场实际舞台或座席配置，只有通用图可用时需要在界面上持续提示。
- `version` 字段支持检测图片内容变化而不仅依赖 URL 是否变化——图片更换但 URL 不变时，`version` 递增，触发对应卡片更新。
- `scope` 决定该图片适用于整场公演还是某一天／某一站，遵循全局规则 2／3。

## Notice（公告）

**用途**：记录变更、取消、延期、退票等重大公告。

**关键字段**：`id`、`eventID`、`kind`（`change` / `cancellation` / `postponement` / `refund` / `other`）、`title`、`body`、`publishedAt`、`sourceURL`、`scope`（`Scope`）。

**不变量**：
- 取消、延期等会影响 `LiveEvent.status` 的重大公告需要同步反映在公演标题区，不能仅依赖 `Notice` 列表中的一条记录，避免用户因未展开某个 Tab 而错过。

## SourceEvidence（来源证据）

**用途**：为其他模型中的具体字段提供可追溯的官方出处，是「所有重要字段都要能回到官方来源」这一原则的落地机制。

**关键字段**：`id`、`recordID`（指向被支持的记录）、`field`（具体字段名，如 `applyEndAt`）、`sourceURL`、`quote`（原文引用）、`sourcePublishedAt`、`verifiedAt`、`verification`（`confirmed` / `needsReview` / `conflict`）。

**不变量**：
- 三个时间戳互不相同（全局规则 5）：来源发布时间、最后成功核对时间、App 下载时间分别记录不同事实；不能因为「较晚抓到」就当作「较新公告」。
- 来源冲突（`conflict`）或需人工复核（`needsReview`）的字段不直接覆盖线上已确认数据。

## Scope（适用范围，值对象）

**用途**：所有与「哪一天／哪些场次」相关的记录（`TicketRound`、`GoodsCampaign`、`MediaAsset`、`Notice`）共用的适用范围表达方式，不是独立的持久化实体。

**取值**：
- `{ "kind": "wholeEvent" }` — 整项公演共通。
- `{ "kind": "stop", "stopID": "…" }` — 指定巡演站点。
- `{ "kind": "performances", "performanceIDs": ["…"] }` — 指定一个或多个场次。
- `{ "kind": "unconfirmed" }` — 适用范围尚未确认。

**不变量**：与全局规则 2／3 完全一致——「没有写 Day2」不会被转换成 `wholeEvent`；解析器无法确定适用范围时必须输出 `unconfirmed`，并在界面上以单独的「适用日期待确认」卡片呈现，不能悄悄当作共通资料展示。

## DataStatus（字段／记录状态，值对象）

**用途**：表达单条记录或字段的可信程度，不是「有／无」二元状态。

**取值**：`confirmed`（已确认）、`officiallyTBA`（官方明确待公布）、`notFetched`（尚未获取）、`parseFailed`（解析失败）、`notApplicable`（不适用）。

**不变量**：抓取失败或解析失败必须标记为 `parseFailed` 并保留上一版已确认数据，绝不能显示为 `officiallyTBA`（全局规则 4）。

## UserEventState（用户关注与申请状态）

**用途**：用户自己的关注、计划参加、申请记录，仅存于 App 本地，不出现在 `LiveEventBundle` JSON 中。

**关键内容**：关注状态、计划参加标记、「我已申请」「我已付款」「我已有基础票」等手动记录。

**不变量**：
- 这些记录由用户手动输入，不能从公开网页推断得出；它们只能决定个人提醒的触发条件，不能修改官方票务事实（如 `TicketRound.officialStatus`）。
- 属于用户数据，清理公共缓存时不能一并删除。

## CardConfiguration（卡片配置）

**用途**：用户对信息卡片的显示／隐藏、排序、密度、提醒等设置，仅存于 App 本地。

**关键内容**：卡片类型 + 对应实体 ID → 显示／隐藏、排序、紧凑／详细、字段选择、变化提醒、截止提醒、适用范围（仅当前公演或作为同类卡片默认配置）。

**不变量**：
- 配置绑定「稳定卡片类型及对应实体 ID」，不能绑定数组下标，否则官网更新导致的顺序变化会破坏用户配置。
- 用户调整后的顺序和隐藏状态不能因为官网数据更新而被重置。
- 与 `UserEventState` 一样属于用户数据，不随公共缓存清理而丢失。

---

## 场景示例

### 示例一：两日公演，共通物贩 + 单日专属物贩

某公演 DAY1／DAY2 各对应一个 `Performance`（同一个 `LiveEvent`，无 `LiveStop`）。官方通贩页在文章中说明「本商品两天通用」，对应一个 `GoodsCampaign`，其 `scope` 为 `{ "kind": "wholeEvent" }`。另有一个仅 DAY1 会场限定发售的商品，对应另一个 `GoodsCampaign`，`scope` 为 `{ "kind": "performances", "performanceIDs": ["<DAY1 的 Performance.id>"] }`。用户切换到 DAY2 时，第二个 `GoodsCampaign` 不再显示在「周边」Tab，因为它的 `Scope` 明确限定在 DAY1；不会因为「文章里没提 DAY2 没有这个商品」就把它误标成整场公演共通。

### 示例二：同日昼夜场

某公演同一天有昼公演与夜公演，对应两个独立的 `Performance` 记录，`localDate` 相同但 `subtitle` 分别为「昼公演」「夜公演」，`doorsAt`／`startAt`／`performers` 各自独立。选择器展示为「日期 → 昼夜场」两级，而不是把两场合并成一个 `Date` 级别的选项，避免开演时间和出演者被混用。

### 示例三：巡演

某巡演包含东京、大阪两个 `LiveStop`，每个站点下各有若干 `Performance`（`stopID` 指向对应站点）。物贩批次如果是「东京站限定」，其 `GoodsCampaign.scope` 为 `{ "kind": "stop", "stopID": "<东京站 id>" }`；如果是全巡演通用周边，则为 `{ "kind": "wholeEvent" }`。首页卡片对该巡演显示站点数量，详情页选择器按「站点 → 日期 → 昼夜场」组织。

### 示例四：抽选轮次 → 一般发售 → 升级受付

同一场公演先后开放三轮受付：
1. **先行抽选**（`TicketRound.kind = "lottery"`）：面向会员，`eligibility` 说明需要会员资格，`applyStartAt`／`applyEndAt`／`resultAt`／`paymentDeadlineAt` 各自独立记录。
2. **一般发售**（`kind = "firstComeFirstServed"`）：在抽选结果公布后另起一轮，`officialName` 与抽选轮次不同，二者作为两条独立的 `TicketRound` 并存，互不覆盖——即使一般发售开始后抽选轮次已结束，抽选轮次的历史记录仍保留（界面上默认折叠已结束轮次）。
3. **升级受付**（`kind = "upgrade"`）：对应的 `TicketOffer.tierID` 指向一个 `priceKind = "upgradeDifference"` 的 `TicketTier`，其 `priceJPY` 是升级差额而非完整票价；界面在票价卡片中需要明确标注这是差额，不能与其他轮次的完整票价（`priceKind = "full"`）混合计入「最低价」。

三轮受付的 `scope` 如果适用于全部场次则为 `wholeEvent`，如果仅适用于特定场次（例如仅东京站可升级）则为 `performances` 或 `stop`，解析器不确定时输出 `unconfirmed` 并单独展示，不与其他轮次的确定范围混淆。
