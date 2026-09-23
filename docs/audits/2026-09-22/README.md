# 官网抓取对比审计 · 2026-09-22

## 结果与范围

完整字段对比覆盖 **BanG Dream! 按官网发布时间排序的 40 个不同 live**。它们来自 41 条发布记录：台北 DAY1／DAY2 的旧链接目前返回字节相同的两日合并页面，因此去重后补入下一条 Morfonica「Maestoso」。

- 修复前：40 场中 **29 场**存在已核验差异，共 **70 个比较断言失败**。一个票价数组或场次数量比较算一个断言，这不是原子字段总数。
- 修复后：同一组已核验断言 **40/40 通过**。独立预期值来自官网原文与人工核查，没有从 app 输出生成预期值。
- Love Live! 首次核查 20 个当前官网详情时，生产 Swift 抓取器 **20/20 返回 HTTP 403**。后续已定位并修复网页及图片请求头，见 [403 修复与复测](lovelive/403-fix.md)。历史失败输出保留。

**跨 BanG Dream!／Love Live! 的全局最新 40 场尚未完成验收。** Love Live! 的访问问题已有后续修复，但分支列表仍未提供完整的跨分支首次发布时间。BanG Dream! 的完整字段对比与 Love Live! 的资料／访问核查分别报告。

## 选样与证据

使用官方公开 WordPress API 的 `events` 类型，筛选官网分类 `tax_events=51`（ライブ），按 `date` 降序。没有将演出日期、修改日期或图片上传日期当作发布时间。测试通过逐公演抓取入口验证旧公演；app 日常自动整理仍遵循手机日期及往前一个月的窗口。

- [官方发布顺序 API](https://bang-dream.com/wp-json/wp/v2/events?tax_events=51&per_page=41&orderby=date&order=desc&_fields=id,date,modified,slug,link,title,tax_events)
- [40 场清单](bangdream/unique40-manifest.json) · [独立预期字段](bangdream/unique40-expected.json)
- [官网原文与定位](bangdream/ground-truth.json) · [HTML SHA-256](bangdream/capture-integrity.json)
- [修复前差异](bangdream/unique40-comparison-before.json) · [修复后比较](bangdream/unique40-comparison-after.json)
- [修复前 app 输出](bangdream/unique40-before.json) · [修复后 app 输出](bangdream/unique40-after.json)
- [BanG Dream! 独立审查报告](bangdream/README.md) · [Love Live! 独立审查报告](lovelive/README.md)

## 修正内容

1. **日期与场次**：识别“日程・会場”“開催概要”；保留同日昼／夜多场；共同注明的开场／开演时间对应到各日期；只公布日期时保留日期精度。
2. **会场与出演**：巡演每站、分段落场次、东京／大阪各自对应会场；排除混入的官网链接；出演者按 DAY 和音乐节出演日期对应，保留官方成员／嘉宾信息。
3. **票价**：兼容“会場チケット”、SOLD OUT 标题、分小标题的 ¥ 票价、免费票及手续费；港币／新台币使用正确币种和最小货币单位。
4. **售票轮次**：解析省略年份与跨年截止日期；分开申请、结果和付款区间；付款截止取终点；不将专辑资格链接当作购票入口；保留受付終了及官方待公布状态；状态变化保持卡片 ID；补录官方转售区块。
5. **公演当地时间**：台北、香港、首尔、洛杉矶使用对应公演时区。手机跨天刷新规则保持原样。
6. **周边与图片**：识别“グッズ情報”“グッズ / CD・Blu-ray販売”；记录销售开始、地点、时段、限购、支付说明；图片关联卡片；会场区域图不因子标题漏抓。
7. **配信**：记录票价、销售窗口、DAY1／DAY2 回看期限及来源证据，可单独重新整理配信卡片。

## 比较范围

自动逐场比较标题、场次数量、已明确的日期／时间／会场／时区、出演者包含及错误场次排除、票价币种／金额、周边图片区块。全角括号、官网缩略图与原图尺寸后缀、额外真实成员介绍视为等价，不掩盖实质差异。票务窗口、配信期限和缓存刷新另有 iOS 回归测试。

没有对图片中的所有商品做 OCR，也没有声称所有外部售票平台内容已结构化。官网未明确公布的值不计为“验证通过”。Love Live! 的实时抓取失败单独保存在 [实际错误输出](lovelive/app-live.json)。

## 最终验证

- iOS 模拟器：**44 项单元测试、1 项 UI 测试全部通过**，其中本次增加 12 项真实官网案例回归测试。
- 40 场已保存官网 HTML 经最终生产解析器回放：40/40 与独立预期字段一致。
- 最终版本实际联网抓取：**40/40 成功**，同一预期字段比较也全部通过。[联网输出](bangdream/unique40-live.json) · [联网对比结果](bangdream/unique40-comparison-live.json)
- [52 个不同图片 URL](bangdream/unique40-image-access.json) 均返回有效图片签名。每个地址读取前 1 KiB，核对 HTTP、MIME 与文件头，没有将 HTML 错误页计为图片；这不等于对整张图片内容做 OCR。
- [结构检查](bangdream/structural-validation.json)：各集合 ID 无重复，申请截止时间没有早于申请开始时间。
- [测试日志摘要](test-results.txt) · [本次解析器修复补丁](scraper-fixes.patch)

## 复现

从仓库根目录运行，脚本直接编译并调用 app 的生产 Swift 抓取器，无需后端：

```sh
scripts/audit/run-official-audit.sh \
  docs/audits/2026-09-22/bangdream/unique40-manifest.json \
  /tmp/live-dashboard-replay.json

# 实时联网，不使用已保存 HTML
scripts/audit/run-official-audit.sh \
  docs/audits/2026-09-22/bangdream/unique40-manifest.json \
  /tmp/live-dashboard-live.json --live

node docs/audits/2026-09-22/bangdream/compare-normalized.mjs \
  /tmp/live-dashboard-replay.json /tmp/comparison.json \
  docs/audits/2026-09-22/bangdream/unique40-expected.json
```

代码修改不会自动替换用户手机上的旧缓存。更新 app 后可手动“重新整理”，或等待下一次符合规则的自动整理。

## 40 场逐场结果

| # | Official live / source | Published | Before: failed assertions | After |
|---:|---|---|---:|---|
| 1 | [Morfonica LIVE「eleganza」](https://bang-dream.com/events/eleganza/) | 2026-09-22 | 0 | PASS |
| 2 | [Roselia 10th Anniversary LIVE TOUR](https://bang-dream.com/events/roselia-10th-anniversary-live-tour/) | 2026-08-30 | 1 | PASS |
| 3 | [WONDERLIVET 2026](https://bang-dream.com/events/wonderlivet-2026/) | 2026-08-27 | 4 | PASS |
| 4 | [NAKAMACHI ARALE LIVE 2026「RESONEXT」](https://bang-dream.com/events/nakamachiarale_live2026/) | 2026-08-16 | 3 | PASS |
| 5 | [Bushiroad Fashion Journey](https://bang-dream.com/events/bushiroad-fashion-journey/) | 2026-07-23 | 2 | PASS |
| 6 | [MyGO!!!!! 9th LIVE「つなぎ目の向こうに」- 神戸再景編 -](https://bang-dream.com/events/mygo_9th_hyogo/) | 2026-07-19 | 0 | PASS |
| 7 | [EVANESCENCE 2026 JAPAN](https://bang-dream.com/events/evanescence_avemujica/) | 2026-07-17 | 6 | PASS |
| 8 | [一家Dumb Rock! 1st GIG「ピース＆グルーヴ」](https://bang-dream.com/events/ikka-dumb-rock_1st/) | 2026-06-26 | 0 | PASS |
| 9 | [millsage LIVE 001「極夜」](https://bang-dream.com/events/millsage_1st/) | 2026-06-26 | 0 | PASS |
| 10 | [TVアニメ「バンドリ！ ゆめ∞みた」放送記念フリーライブ「新宿着陸計画」DAY2](https://bang-dream.com/events/yumemita_2026free/) | 2026-06-21 | 2 | PASS |
| 11 | [Ave Mujica 7th LIVE「Virtus」](https://bang-dream.com/events/avemujica_7th/) | 2026-06-17 | 0 | PASS |
| 12 | [KIMCHIKURA Fes '26](https://bang-dream.com/events/kimchikura-fes-26/) | 2026-06-04 | 2 | PASS |
| 13 | [BM-ECHOES FESTIVAL 2026](https://bang-dream.com/events/bm-echoes-festival-2026/) | 2026-05-31 | 1 | PASS |
| 14 | [BEAT AX -SUMMER EDITION 2026-](https://bang-dream.com/events/25941/) | 2026-05-22 | 1 | PASS |
| 15 | [ナガノアニエラフェスタ2026](https://bang-dream.com/events/anierafesta2026/) | 2026-05-15 | 3 | PASS |
| 16 | [FEST. INAZUMA 2026](https://bang-dream.com/events/fest-inazuma2026/) | 2026-05-08 | 5 | PASS |
| 17 | [BanG Dream! 13th☆LIVE DAY2 : 夢限大みゅーたいぷ「DIMENSIONAL OVERLAP」](https://bang-dream.com/events/13th-live-day2/) | 2026-05-03 | 0 | PASS |
| 18 | [BanG Dream! 13th☆LIVE DAY1 : Poppin'Party「Now Roading♪♪」](https://bang-dream.com/events/13th-live-day1/) | 2026-05-03 | 0 | PASS |
| 19 | [BanG Dream! 13th☆LIVE DAY3 : RAISE A SUILEN「EXTREME EXPRESS」](https://bang-dream.com/events/13th-live-day3/) | 2026-05-03 | 0 | PASS |
| 20 | [Anime Expo 2026「J-POP SOUND CAPSULE」](https://bang-dream.com/events/jsc2026/) | 2026-04-30 | 2 | PASS |
| 21 | [MUSIC AWARDS JAPAN WEEK SPECIAL LIVE リスアニ！LIVE on TOKYO ANIME MUSIC HIGHLIGHTS](https://bang-dream.com/events/maj_lisani2026/) | 2026-04-01 | 1 | PASS |
| 22 | [SUMMER SONIC 2026](https://bang-dream.com/events/summer-sonic-2026/) | 2026-03-25 | 4 | PASS |
| 23 | [Animelo Summer Live 2026 -Messenger-](https://bang-dream.com/events/asl2026/) | 2026-03-22 | 4 | PASS |
| 24 | [LuckyFes'26](https://bang-dream.com/events/luckyfes2026/) | 2026-03-10 | 1 | PASS |
| 25 | [Roselia「Lehre der Rose」 - Roselia 10th Anniversary Best Album「Lehre der Rose」リリース記念ライブ](https://bang-dream.com/events/lehre-der-rose/) | 2026-02-15 | 1 | PASS |
| 26 | [CENTRAL MUSIC & ENTERTAINMENT FESTIVAL 2026](https://bang-dream.com/events/central_music_entertainment_festival_2026/) | 2026-02-06 | 2 | PASS |
| 27 | [BanG Dream! Special LIVE in TAIPEI](https://bang-dream.com/events/bsl-taipei2026-day1/) | 2026-02-05 | 9 | PASS |
| 28 | [FLOW THE FESTIVAL 2026](https://bang-dream.com/events/flowthefestival2026/) | 2026-01-26 | 3 | PASS |
| 29 | [夢限大みゅーたいぷ 47都道府県制覇の旅「スーパーポジション 〜スピンアップ編〜」東京公演](https://bang-dream.com/events/yumemita_superposition_spinup_tokyo_final/) | 2026-01-23 | 1 | PASS |
| 30 | [夢限大みゅーたいぷ 47都道府県制覇の旅 「スーパーポジション ～ゆめんそーれ沖縄～」](https://bang-dream.com/events/yumemita_superposition_yumensore_okinawa/) | 2026-01-23 | 1 | PASS |
| 31 | [RAISE A SUILEN LIVE 2026「Boot IGNITION」香港公演](https://bang-dream.com/events/ras_2026/) | 2026-01-15 | 2 | PASS |
| 32 | [Morfonica LIVE「Movement」](https://bang-dream.com/events/morfonica_live_2026/) | 2025-12-30 | 1 | PASS |
| 33 | [MyGO!!!!! 9th LIVE「つなぎ目の向こうに」](https://bang-dream.com/events/mygo_9th/) | 2025-12-06 | 2 | PASS |
| 34 | [Poppin'Party×Roselia 合同ライブ「DREAMS GO ON」](https://bang-dream.com/events/ppp-roselia2026/) | 2025-11-22 | 0 | PASS |
| 35 | [MEGA VEGAS 2026](https://bang-dream.com/events/megavegas2026/) | 2025-10-10 | 2 | PASS |
| 36 | [リスアニ！LIVE 2026](https://bang-dream.com/events/lisani2026/) | 2025-10-03 | 1 | PASS |
| 37 | [夢限大みゅーたいぷ 47都道府県制覇の旅「スーパーポジション 〜スピンアップ編〜」福岡公演](https://bang-dream.com/events/yumemita_superposition_spinup/) | 2025-09-07 | 2 | PASS |
| 38 | [ARALE Acoustic LIVE ～Copal～](https://bang-dream.com/events/arale_acousticlive2025/) | 2025-08-16 | 1 | PASS |
| 39 | [MyGO!!!!!×Ave Mujica ツーマンライブ「“moment / memory”」](https://bang-dream.com/events/mygo-avemujica2026/) | 2025-08-14 | 0 | PASS |
| 40 | [Morfonica 5th Anniversary LIVE「Maestoso」](https://bang-dream.com/events/morfonica_live_2025/) | 2025-08-14 | 0 | PASS |

## 后续修正与联网复测（2026-09-23）

使用同一审计工具对 Love Live! 20 个当前官网详情页做了联网复测（`docs/audits/2026-09-22/lovelive/replay-manifest.json --live`），并与 `lovelive/current-event-facts.json` 逐场比对。修正前 20 场中有 13 场存在场馆或场次错误；修正后 20/20 解析成功，日期、场次数量、场馆均与官网一致（场馆比对时把 `都道府県・` 前缀与全角括号视为等价）。BanG Dream! 40 场联网对比保持 40/40。

- **叠行标签**：`【会場】` 与场馆名分两行时之前解析为空（LL03/04/05/10/15/17，以及 LL06 六场）。现在明确标签允许取下一行的值；出演者也支持 `【出演】` 叠行与独立 `出演者` 标题。
- **巡演每站场馆**：多站页面此前把第一站场馆套给所有日期（LL07/11/12/18/19）。新增按整行 `＜…＞` 站点标题分块，把每个日期映射到本站场馆与城市。
- **同日多场与重复场次**：`1日目 昼の部：` 这类标签在日期之前时被合并成一场（LL13 4 场变 2 场）；`■お問い合わせ` 的电话时段被误当作开场／开演（LL18 多出一场）。现在开场／开演配对必须同行含关键字，DAY 与昼夜／第 N 回公演分别写入 `dayLabel` 与 `subtitle`。
- **场次 ID 重复**：再次整理时同名标签会复用同一缓存 ID（LL02/06/07/08/09/11/12/18/19/20）。改为两轮匹配并保证 ID 在同一公演内唯一；两次整理的 ID 集合一致。
- **售票轮次／票价 ID 重复导致崩溃**：Love Live! 页面同一票务区块出现在多个容器中，产生同 ID 的轮次和票价（LL08/13/18 等），打开「チケット」页会崩溃。解析时按 ID 去重，卡片排序策略也不再因重复 ID 中断。

仍未覆盖：LL09/LL11/LL16/LL20 的出演者在官网以其他版式呈现，仍为空；`current-event-facts.json` 保存的是简化场馆名，比对需做前缀与括号归一化。iOS 单元测试 97 项、UI 测试 1 项通过。
