# 官方来源登记表

本表登记 `docs/DESIGN.md` 第一节「官方信息源应该接入哪些网站」中列出的全部官方入口 URL，标注模板类型、对应解析适配器（第二节）、抓取频率建议（第七节规则），以及对应的 HTML 快照文件名（见 `server/tests/fixtures/snapshots/MANIFEST.md`，抓取日期 2026-09-22，均返回 HTTP 200）。

## 抓取频率规则（依据 DESIGN.md 第七节）

DESIGN.md 第七节规定的通用原则是：**抓取频率从低频开始，对正在受付、接近开演的公演适当提高；遵守来源站点规则、限流与重试要求。** 据此，本表将频率分三档：

| 档位 | 触发条件 |
|---|---|
| **低频** | 默认档位。该来源当前未关联任何进行中受付或临近开演（例如 30 天以上）的公演。 |
| **中频** | 该来源关联的公演已有已知未来事项（受付即将开始、通贩批次即将开放、开演日期在数周内）。 |
| **高频** | 该来源关联的公演正处于受付进行中、通贩批次销售中，或开演日期临近（例如 7 天内）。 |

发现型列表页（events 索引、live.php 列表、官方新闻）默认低频，因为其内容变化频率低于单场公演详情页；详情页与通贩文章的档位随公演生命周期动态调整。

## BanG Dream!

| 企划 | 入口 | 模板类型 | 对应适配器 | 抓取频率建议 | 快照文件名 |
|---|---|---|---|---|---|
| BanG Dream! | https://bang-dream.com/events/ | Live／Event 列表 | `BangDreamEventIndexAdapter` | 低频（默认发现节奏） | `bangdream_events_index.html` |
| BanG Dream! | https://bang-dream.com/events/mygo-avemujica2026/ | 公演详情 | `BangDreamEventDetailAdapter` | 低频 → 受付进行中或临近开演时提至中频／高频 | `bangdream_event_mygo_avemujica2026.html` |
| BanG Dream! | https://bushiroad-store.com/blogs/live | 通贩 Live 文章列表 | `BushiroadLiveGoodsAdapter` | 低频 → 新批次上线期间提至中频 | `bushiroad_store_live_index.html` |

## Love Live!

| 企划 | 入口 | 模板类型 | 对应适配器 | 抓取频率建议 | 快照文件名 |
|---|---|---|---|---|---|
| Love Live! | https://www.lovelive-anime.jp/ | 系列主站 | `LoveLiveNewsAdapter`（作为新闻/公告发现入口的一部分） | 低频 | 无独立快照（未在 MANIFEST 中单独抓取） |
| Love Live! | https://www.lovelive-anime.jp/news/ | 官方新闻列表 | `LoveLiveNewsAdapter` | 低频 → 有活跃公演追踪时提至中频 | `lovelive_news.html` |
| Love Live!（Aqours） | https://www.lovelive-anime.jp/uranohoshi/live.php | Aqours Live 列表（旧模板 `.php`） | `LoveLiveLegacyPageAdapter` | 低频 | `lovelive_aqours_live.html` |
| Love Live!（虹咲） | https://www.lovelive-anime.jp/nijigasaki/live.php | 虹咲 Live 列表（旧模板 `.php`） | `LoveLiveLegacyPageAdapter` | 低频 | `lovelive_nijigasaki_live.html` |
| Love Live!（Liella!） | https://www.lovelive-anime.jp/yuigaoka/live/ | Liella! Live 列表 | `LoveLiveIndexAdapter` | 低频 | `lovelive_liella_live.html` |
| Love Live!（莲之空） | https://www.lovelive-anime.jp/hasunosora/live-event/ | 莲之空 Live／Event 列表 | `LoveLiveIndexAdapter` | 低频 | `lovelive_hasunosora_live_event.html` |
| Love Live!（LOVELIVE! BLUEBIRD） | https://www.lovelive-anime.jp/lovehigh/live/ | イキヅライブ！Live／Event 列表 | `LoveLiveIndexAdapter` | 低频 | `lovelive_lovehigh_live.html` |
| Love Live!（跨系列） | https://www.lovelive-anime.jp/special/live/live_detail.php?p=15th_lovelivefest | 新式特设详情页 | `LoveLiveDetailAdapter` | 低频 → 受付进行中或临近开演时提至中频／高频 | `lovelive_detail_15th_lovelivefest.html` |
| Love Live! | https://lovelive-store.bnfw.jp/ | 官方通贩门户 | `LoveLiveGoodsStoreAdapter` | 低频 → 新批次上线期间提至中频 | `lovelive_store_portal.html` |
| Love Live! | https://lovelive.fannect.jp/ | School idol STORE（实际 Live Goods 店铺） | `LoveLiveGoodsStoreAdapter` | 低频 → 销售期间提至中频／高频 | `lovelive_fannect_store.html` |

## 补充抓取样本（适配器测试用，非独立官方入口）

以下快照未在 DESIGN.md 第一节的官方入口表中单列，但属于第一节所述来源的具体文章／页面实例，用于验证对应适配器处理「按 DAY 拆分」「巡演」等场景，登记于此以便与 MANIFEST 对齐：

| 企划 | 说明 | 模板类型 | 对应适配器 | 快照文件名 |
|---|---|---|---|---|
| BanG Dream! | Bushiroad 通贩文章，按 DAY 拆分示例 | 通贩文章 | `BushiroadLiveGoodsAdapter` | `bushiroad_goods_bangdream13th_day1.html` |
| BanG Dream! | Bushiroad 通贩文章，巡演示例 | 通贩文章 | `BushiroadLiveGoodsAdapter` | `bushiroad_goods_avemujica_tour2026.html` |
| Love Live! | 门户 LIVE GOODS 链接指向的旧站（迁移公告） | 迁移公告页 | `LoveLiveGoodsStoreAdapter` | `lovelive_legacy_goods_store_redirect.html` |

---

## 别名与迁移

已核实的 Love Live! 通贩入口迁移链（详见 `docs/DESIGN.md` 第一节）：

```text
https://lovelive-store.bnfw.jp/ （官方通贩门户）
    └─ LIVE GOODS 链接
        ↓
https://official-goods-store.jp/lovelive/ （旧站）
    └─ 显示迁移公告（快照：lovelive_legacy_goods_store_redirect.html）
        ↓ 指向
https://official-goods-store.jp/lovelive/maintenance/ （维护／迁移说明页）
        ↓
https://lovelive.fannect.jp/ （School idol STORE，实际 Live Goods 店铺，快照：lovelive_fannect_store.html）
```

**采集规则**：必须保存这条来源迁移／别名关系，把旧地址（`official-goods-store.jp`）与新地址（`lovelive.fannect.jp`）识别为同一逻辑来源的两个历史坐标，而不能把旧地址出现维护页简单解释为「通贩结束」或「公演消失」。当旧地址仍返回维护公告时，采集器应沿链跟随至 `lovelive.fannect.jp` 获取实际物贩内容，并在 `SourceEvidence` 中保留完整跳转路径供审核核对。

## URL 归一化规则

对所有登记入口生效的通用规则：

1. **剥离追踪参数**：`utm_*`（`utm_source`／`utm_medium`／`utm_campaign` 等）、`fbclid`、`gclid` 等广告／统计跟踪参数一律移除，不参与来源标识与去重比较。
2. **按白名单保留有语义的参数**：不能清除全部查询参数——部分参数是公演或页面身份的一部分。已知白名单：
   - `p`：`lovelive-anime.jp` 的 `live_detail.php?p=…`，标识具体公演，去掉会把不同公演错误合并。
   - `page`：`bushiroad-store.com` 列表页的分页参数，去掉会丢失分页定位，但不影响身份判断（仅影响发现阶段的遍历，需要采集器自行处理分页，不作为记录身份的一部分）。
3. 不在白名单内、且不属于已知追踪参数的查询参数，遇到时应保守保留并记录，交由人工审核判断是否需要新增白名单条目，不擅自丢弃可能影响身份判断的未知参数。
