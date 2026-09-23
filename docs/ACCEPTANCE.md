# 验收清单

本清单展开 `docs/DESIGN.md` 第八节「必须通过的验收」表，为每个场景补充前置数据、操作、预期结果与验证位置（测试名为占位，实现时对齐实际测试文件）。

---

## 1. Day1 切换到 Day2

- **前置数据**：一个 `LiveEvent` 含两个 `Performance`（DAY1／DAY2），每场各自的价格（`TicketOffer`）、售票链接（`TicketRound`）、座位图（`MediaAsset`，`kind = eventSeatingMap`）、场贩范围（`GoodsCampaign.scope`）均不同。
- **操作**：在详情页将 `selectedPerformanceID` 从 DAY1 切换到 DAY2。
- **预期结果**：概要、售票、座位、周边四个 Tab 的内容同时按新的 `selectedPerformanceID` 重新匹配；不出现 DAY1 的价格/链接/座位图残留在 DAY2 视图中的情况。
- **验证位置**：`ios/LiveDashboardKit/Tests/PerformanceSwitchingTests.swift` — 占位测试名 `testAllTabsFollowSelectedPerformanceID`。

## 2. 同日昼夜场

- **前置数据**：同一 `localDate` 下两个独立 `Performance`，`subtitle` 分别为「昼公演」「夜公演」，`doorsAt`／`startAt`／`performers` 均不同。
- **操作**：选择器在同一日期下选择昼场，再切换到夜场。
- **预期结果**：开场／开演时间与出演者列表分别对应各自场次，不发生混用或合并显示。
- **验证位置**：`ios/LiveDashboardKit/Tests/PerformanceScopeResolverTests.swift` — 占位测试名 `testSameDayMatineeEveningNotMerged`。

## 3. 多轮受付同时存在

- **前置数据**：同一公演下三个 `TicketRound`（先行抽选、一般发售、升级受付），各自 `applyStartAt`／`applyEndAt`／`eligibility`／`officialStatus` 不同；`TicketOffer` 分别关联不同 `TicketTier`（含 `priceKind = upgradeDifference` 的一轮）。
- **操作**：加载售票 Tab，查看三轮受付卡片；模拟新一轮受付发布。
- **预期结果**：每轮时间、资格、价格关系独立展示；新轮次发布后旧轮次记录仍保留（默认折叠），不被覆盖或删除。
- **验证位置**：`ios/LiveDashboardKit/Tests/TicketStatusResolverTests.swift` — 占位测试名 `testConcurrentRoundsRemainIndependent`；服务端侧对应 `server/tests/test_ticket_round_parsing.py` — 占位测试名 `test_multiple_rounds_do_not_overwrite_each_other`。

## 4. 一个通贩页关联多日

- **前置数据**：一篇 Bushiroad／Love Live! 通贩文章正文说明商品适用于「两天通用」，另有一商品仅标注 DAY1。
- **操作**：运行对应 `BushiroadLiveGoodsAdapter` 或 `LoveLiveGoodsStoreAdapter` 解析该快照 HTML。
- **预期结果**：两天通用的商品生成 `GoodsCampaign.scope = { kind: wholeEvent }`；仅 DAY1 的商品生成 `scope = { kind: performances, performanceIDs: [DAY1] }`；不为每一天各自复制一份导致 DAY2 出现冲突或重复的物贩记录。
- **验证位置**：`server/tests/test_goods_campaign_scope.py` — 占位测试名 `test_goods_campaign_scope_resolution`，以 `bushiroad_goods_bangdream13th_day1.html` 为输入。

## 5. 旧网页或店铺迁移

- **前置数据**：`lovelive-store.bnfw.jp` 门户的 LIVE GOODS 链接、`official-goods-store.jp/lovelive/` 迁移公告快照、`lovelive.fannect.jp` 实际店铺快照（对应 `docs/SOURCES.md`「别名与迁移」链条）。
- **操作**：采集器依次抓取门户 → 旧站 → 新站；解析旧站内容。
- **预期结果**：旧站返回维护／迁移公告时，系统保留来源别名关系并沿链获取新站内容，不将其误报为「公演消失」或「通贩结束」。
- **验证位置**：`server/tests/test_source_alias_chain.py` — 占位测试名 `test_lovelive_goods_store_alias_chain`。

## 6. 抓取失败／字段缺失

- **前置数据**：已存在一版 `confirmed` 状态的记录；模拟下一次抓取时目标页面结构变化导致解析异常。
- **操作**：触发解析器在异常输入下运行（例如截断或改变快照 HTML 结构）。
- **预期结果**：系统保留上一版已确认数据，新记录状态标记为 `parseFailed`；界面明确显示核对问题，不显示为 `officiallyTBA`（官方尚未公布）。
- **验证位置**：`server/tests/test_parse_failure_handling.py` — 占位测试名 `test_parse_failure_preserves_last_confirmed_and_flags_status`。

## 7. 用户配置后更新数据

- **前置数据**：用户已隐藏某张卡片、调整排序、置顶某项、设置提醒（`CardConfiguration` 已持久化）；服务端随后发布新版本 `LiveEventBundle`（字段更新但实体 ID 不变）。
- **操作**：App 同步新版本数据。
- **预期结果**：隐藏、排序、置顶、提醒设置保持不变，仅卡片内部数据（价格、时间等）更新；配置绑定的是卡片类型＋实体 ID，不受服务端字段变化影响。
- **验证位置**：`ios/LiveDashboardKit/Tests/CardConfigurationTests.swift` — 占位测试名 `testConfigSurvivesDataRefresh`。

## 8. 图片更换但 URL 不变

- **前置数据**：某 `MediaAsset` 的 `originalURL` 保持不变，但服务端检测到图片内容哈希变化。
- **操作**：服务端重新抓取并比对图片内容；App 端同步该 `MediaAsset`。
- **预期结果**：`MediaAsset.version` 递增，App 识别为新版本并更新对应图片卡片的缓存与展示，不因 URL 相同而跳过更新。
- **验证位置**：`ios/LiveDashboardKit/Tests/MediaCacheTests.swift` — 占位测试名 `testContentChangeDetectedWithoutURLChange`；服务端侧 `server/tests/test_media_asset_versioning.py` — 占位测试名 `test_image_content_change_increments_version`。

## 9. 离线、重启、大字体

- **前置数据**：详情页已完整缓存（含图片）；App 处于离线状态或被杀死重启；系统设置为放大字号（Dynamic Type 大字体档位）。
- **操作**：离线打开已缓存公演详情页；重启 App 后重新进入同一详情页；在大字体设置下浏览各 Tab。
- **预期结果**：已缓存详情内容可正常阅读；场次／Tab 选择状态在重启后合理恢复（例如回到上次浏览的 `Performance`）；大字体下文字与控件不被裁切、不重叠。
- **验证位置**：`ios/LiveDashboardApp/UITests/OfflineRestoreTests.swift` — 占位测试名 `testCachedDetailReadableAfterRestart`；`ios/LiveDashboardApp/UITests/DynamicTypeLayoutTests.swift` — 占位测试名 `testLargeAccessibilityFontNoClipping`。
