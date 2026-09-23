# LiveDetail：逐元素 UI 实现审计

审查范围是 `LiveDetailView` 全部四个分区、`DetailCard`/`DetailCardMenu`、场次选择、官方链接、官方媒体与全屏查看、页面和卡片翻译，以及 `AssistantSummaryCard`、`AssistantRichTextView`、`AssistantLinksSection`。依据 `apple-like-ui`、Apple HIG synthesis 与 `ios-dev` 的设计和可访问性原则，只读检查当前工作树实现。

源码入口：[详情框架](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/LiveDetailView.swift)、[概要与共享卡片](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/Overview/OverviewView.swift)、[卡片菜单与翻译](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/DetailCardMenu.swift)、[票务](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/Tickets/TicketsView.swift)、[周边](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/Goods/GoodsView.swift)、[座位](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/Seating/SeatingView.swift)、[媒体](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/OfficialMediaView.swift)、[官方链接](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/OfficialLinksView.swift)、[场次选择](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/PerformanceSelector.swift)、[AI 摘要](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Assistant/AssistantSummaryCard.swift)、[AI 富文本](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Assistant/AssistantRichTextView.swift)、[AI 链接](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Assistant/AssistantLinksSection.swift)。表中行号是读取时定位；工作区在审查期间仍有其他修改，优先按元素及符号名定位。

末轮补充：详情新增 `dataSourceSelector`，两项 segmented `Picker` 绑定 `store.usesAssistantData`，仅在 `hasAssistantData` 时显示，AI 模式下有 caption 说明。**保留单选控件，调整命名和作用域提示（P1）**：标签“AI 重新整理”像执行命令，实际为切换已保存资料，宜改“AI 整理结果”；明确它影响下方全部分区，并在滚动后仍可辨认当前资料来源。与“重新生成 AI 结果”的 Button 保持清楚区分。来源切换后的场次有效性、空结果和过期资料提示需联动验证。位置：[LiveDetailView.dataSourceSelector](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/LiveDetail/LiveDetailView.swift:154)。

补充媒体动效：`NativeImageZoomView` 的双击/辅助功能缩放使用 `animated: true`，当前未读取 Reduce Motion。建议根据 `UIAccessibility.isReduceMotionEnabled` 控制程序缩放动画；保留用户直接捏合操作。它不受 SwiftUI 的 `motionAnimation` modifier 自动管理。

## 结论边界与标记

- **保留**：代码已明确实现合适的平台模式、状态或可访问性语义。
- **调整**：当前可用，但信息层级、密度或动作组织有明确改进空间。
- **缺陷**：由代码即可确定的遗漏或错误路径，不依赖截图判断。
- **待验证**：SwiftUI 系统控件会继承 Dynamic Type、系统命中和平台行为，单凭源码不能断言最终布局或触控面积有问题；必须在模拟器或真机渲染后判断。
- **P1/P2/P3**：分别表示核心任务/恢复路径、主要体验质量、次要精修。

本审计不把 `.font(.caption)` 自动等同于小命中区，也不把 `Picker`、`Link`、`Toggle`、`DisclosureGroup` 等系统控件自动判定为不支持 Dynamic Type。对固定横排、`.controlSize(.small)`、长日文和辅助功能字号的判断均明确标为待验证，除非代码本身缺少必要状态或路径。

## 页面骨架与全局操作

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 页面滚动容器 | `ScrollView` 内 `LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders])`，整体 `.padding()` | **保留。** 长页面使用惰性纵向布局，选择器可固定；结构适合多卡片详情。 | 保持。需在 iPhone SE、常规 iPhone、iPad split view 验证 pinned header 的高度不会遮挡首张卡片。 | `LiveDetailView.swift:37-89` |
| 公演大标题 | `OfficialText` + `.largeTitle.bold()` + 纵向 `fixedSize` + `.isHeader`；导航栏同时使用同一标题且 `.inline` | **调整 · P2。** 文本可换行、header 语义正确；正文大标题与 inline 导航标题可能在首屏重复。 | 保留可换行和 header trait；渲染验证滚动前后的重复感。若重复明显，正文标题仅在导航标题尚未可见时保留，或改为较低一级标题。 | `LiveDetailView.swift:40-43, 90-91` |
| 顶部关注/参加/提醒动作 | 两个 button-style `Toggle` 和一个 bordered `Button`，均为 capsule；由 `FlowLayout(horizontalSpacing: 8, verticalSpacing: 8)` 自动换行 | **保留。** 选中标签和星标同时变化，不只靠颜色；新 FlowLayout 比固定 HStack 更能承受长文案和大字号。 | 保留；为“计划参加”选中态确认系统 button toggle 的视觉差异足够。`FlowLayout` 目前从 `bounds.minX` 放置，若应用支持 RTL，应按 `layoutDirection` 镜像。 | `LiveDetailView.swift:212-250`; `FlowLayout.swift:6-33, 41-60` |
| 行程提醒结果 | 操作后以 `.caption`、`.secondary` 的 `Text` 就地显示；无图标或成功/失败状态字段 | **调整 · P2。** 位置接近动作，但权限拒绝、过期、成功和系统错误使用同一视觉语义。 | 像卡片刷新反馈一样保存 success/failure 状态，并用文字+图标区分；字体可以继续使用 caption，问题是语义而非命中区。 | `LiveDetailView.swift:60, 276-285` |
| 卡片刷新反馈 | `Label` 根据 `cardRefreshSucceeded` 切换 `checkmark.circle`/`exclamationmark.circle` 和 positive/critical 色；切换 tab/场次时清除 | **保留。** 状态由图标、文本、颜色共同表达，且不会跨上下文遗留。 | 可在成功/失败完成时发一次 accessibility announcement；不要自动消失到来不及朗读。 | `LiveDetailView.swift:61-69, 132-133, 288-315` |
| 官方公演页入口 | 普通 `Link`，仅 `.font(.subheadline)`，位于动作与 critical notices 之间 | **调整 · P1。** 官方来源重要但视觉权重较弱；同时它先于取消/延期/退款通知，使风险信息后置。 | 将 `criticalNotices` 移到标题/场次之后、普通动作之前；官方页入口使用带 `arrow.up.right.square` 的 `Label`，并作为通知和空状态的恢复路径复用。 | `LiveDetailView.swift:56-78` |
| 严重通知卡 | 每条为 `VStack`；标题 `Label(exclamationmark.triangle.fill)`、headline，正文 subheadline，来源 `Link`；critical 色 14% 圆角背景 | **保留实现，调整位置 · P1。** 图标、文字和背景共同传达风险，内容结构清楚；当前顺序降低紧迫性。 | 保持卡片样式，将其前移。多条通知时考虑合并相同 kind 或增加发布时间，防止红色卡片连排淹没后续内容。 | `LiveDetailView.swift:261-274` |
| 分区选择 | 四项 `Picker(selection:)` + `.segmented`；label 为“分区”但视觉由 picker style 决定 | **待验证 · P1。** 系统 segmented picker 支持系统字体与辅助技术，不能从代码断言不支持大字；但四个中文分区在窄屏/辅助功能字号存在压缩或截断风险。 | 用 AX3–AX5、最长本地化和 320pt 宽度渲染。若任一 segment 截断，改为横向 selection strip 或菜单式 picker，不要缩小字体。 | `LiveDetailView.swift:198-209` |
| 顶部工具栏：AI、历史、翻译 | 最多三个 `.topBarTrailing` `ToolbarItem`；AI 生成中替换为 `ProgressView`，未登录 disabled；翻译状态也替换为 spinner | **待验证 · P2。** 系统 toolbar 会处理紧凑呈现，但三项并列是否折叠、标签是否只显图标依设备而定。状态和 a11y label 已存在。 | 小屏和大字号实测 toolbar overflow。若信息被折叠得难以发现，把历史与翻译放入单一 `Menu`，保留最常用动作直达；AI spinner 可增加取消入口或在卡片内提供。 | `LiveDetailView.swift:96-123, 159-179` |
| 分区切换过渡 | `selectedContent` 使用 `.transition(.opacity)` 和自定义 `.motionAnimation(store.selectedTab)`；modifier 在 Reduce Motion 时关闭动画 | **保留。** 动画短、只表达状态切换，并尊重 Reduce Motion。 | 保持；无需额外 slide/scale。 | `LiveDetailView.swift:78-80`; `MotionSupport.swift:3-11` |
| 更新历史 sheet | `.sheet` 展示 `NavigationStack + List`；空态 `ContentUnavailableView`；变更行 headline/subheadline/date；来源区使用 `LabeledContent`、`DisclosureGroup`、可选中文本和 Link；“完成”关闭 | **保留。** focused task 用 sheet，列表与 disclosure 适合扫描和渐进披露。 | `sourceHealth.rawValue` 是内部枚举直出，改为本地化可读标签；发布时间用事件时区/统一格式。证据超过 20 条的截断应在 UI 说明“仅显示前 20 条”。 | `LiveDetailView.swift:319-365` |

## 场次选择与共享卡片框架

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 场次 selection strip | 多场次时创建 `HorizontalSelectionStrip`；label 拼接日期、day label、副标题、多站点名称 | **保留/待验证。** 选择是直接可见的，不藏进菜单；长标签可能产生很宽的 chip，但横向滚动本身是合理模式。 | 给 strip 上方增加可见“场次”小标题或把标题纳入首个辅助文本；当前“场次”只作为整体 accessibility label。渲染验证超长站点和副标题下是否能看见下一项的一部分以提示可滚动。 | `PerformanceSelector.swift:21-40` |
| 横向滚动行为 | `ScrollViewReader + ScrollView(.horizontal) + HStack(spacing: 8)`；隐藏指示器；出现和 selection 变化时滚到 center | **保留。** 选中场次始终回到可视区；Reduce Motion 时不使用动画。 | 可在 VoiceOver 下验证选中后焦点没有被程序滚动打断。隐藏指示器后应通过视觉露出下一 chip 暗示可滚动。 | `HorizontalSelectionStrip.swift:24-52` |
| 场次 chip | `Button`，subheadline，选中 semibold，水平 padding 14、`minHeight: 44`；selected 为 borderedProminent，其他 bordered；selection feedback + `.isSelected` | **保留。** 明确满足 44pt 最小高度，选中态不只靠颜色，系统按钮继承 Dynamic Type。 | 不设置单行 `lineLimit(1)`；长标签允许换行或用两层结构（日期为主、地点为副）。当前是否换行需渲染验证。 | `HorizontalSelectionStrip.swift:58-87` |
| `DetailCard` 容器 | `VStack`，compact/detailed 控制 spacing 5/8 与 padding 10/16；`.background(.background.secondary, RoundedRectangle(cornerRadius: 14))` | **调整 · P2。** 一致、语义化背景且适配明暗模式；所有内容都用同一浮卡会令页面密度高、层级同质。 | 保留对真正独立实体的卡片。对 section 内次级说明、链接集合避免再套卡；通过 section 标题、DisclosureGroup 和间距降低卡片连排感。 | `OverviewView.swift:315-334` |
| 卡片标题行 | `HStack`：headline 标题 + 条件 `ProgressView(.small)` + `Spacer` + menu；标题有 `.isHeader` | **保留/待验证。** 标题语义和卡片内刷新状态清楚。长官方标题与固定 trailing menu 是否挤压需渲染；系统 Text 可换行，不能直接判为截断。 | 在长日文标题与 AX5 下测试；若 menu 被挤出，标题加 `layoutPriority(1)` 并允许多行，menu 保持固定。 | `OverviewView.swift:319-330` |
| 卡片刷新实体 | 配置 identity 使用 `entityID`；实际刷新可用单独 `refreshEntityID`，概览的时间/出演传当前 performance id | **保留。** 配置持久化和当前场次刷新范围被正确分开，避免刷新 global placeholder。 | 为票价/入场等全局卡确认 repository 是否接受 global id；这是数据行为验证，不是视觉调整。 | `OverviewView.swift:97-101, 148-152, 246-313`; `DetailCardMenu.swift:63-94, 108-120` |
| 卡片 menu 入口 | `Menu` label 为 `ellipsis.circle` icon-only；隐藏的文字 label 为“标题 选项”；显式 `frame(minWidth: 44, minHeight: 44)` + contentShape | **保留。** 命中区和辅助名称明确，适合低频卡片定制。 | 若同页卡片很多，可将标题从 label 中移到 accessibility label，避免 VoiceOver 重复朗读超长官方名；需实测朗读体验后决定。 | `DetailCardMenu.swift:180-189` |
| 刷新此卡片 | menu 内 `Button`；全局刷新进行中时文案“正在刷新…”且 disabled；assistant summary 不显示 | **保留。** 异步重复提交受控，进度同时在对应卡片标题显示。 | 当前任何一张卡刷新都会禁用所有卡的刷新，符合串行 repository 设计；若未来允许并发，再按 active key 禁用。 | `DetailCardMenu.swift:108-121`; `OverviewView.swift:309-325` |
| 置顶开关 | menu 内原生 `Toggle`，修改持久化 `CardConfiguration.isPinned` | **保留。** 二元偏好使用 Toggle，状态由系统 menu 呈现。 | 若置顶会跨分区或只在当前分区生效，在菜单文案中明确作用域；视觉本身无需自定义。 | `DetailCardMenu.swift:123-134` |
| 显示密度 picker | menu 内 `Picker` 两项“紧凑/详细”，更新 `CardConfiguration.density` | **保留。** 两项互斥设置使用 picker 合适，且不占卡片常驻空间。 | “紧凑”目前同时降低 padding/spacing并隐藏部分内容；可改文案为“精简/完整”或在 Card Settings 解释内容差异，避免把信息隐藏理解为纯视觉密度。 | `DetailCardMenu.swift:136-150`; `OverviewView.swift:315-334` |
| 隐藏卡片 | menu 分隔线后的 `Button` 写 `isHidden = true`，通知父页显示撤销行 | **保留。** 可逆操作无需破坏性确认；立即提供撤销。 | 当前 `Button` 无 destructive role是合理的，因为可恢复。保持。 | `DetailCardMenu.swift:168-179` |
| 隐藏卡片汇总 | `HiddenCardsFooter`：footnote 文本 + Spacer + “恢复显示”按钮 | **保留/待验证。** 提供持久恢复路径；按钮字号不是命中区证据。 | AX5 下验证单行 HStack；若文本和按钮拥挤，用 `ViewThatFits` 纵向排列。 | `DetailCardMenu.swift:193-218` |
| 5 秒撤销行 | `HStack` + secondary footnote + “撤销”；8pt padding 和二级背景；`.task(id:)` 5 秒后消失 | **调整 · P1。** 不同卡片会重启 timer 已正确；但定时消失的唯一即时撤销不利于部分认知/动作受限用户，虽然仍有 footer 恢复路径。 | 保留底部永久恢复路径；撤销行可延长到 8–10 秒，或在 VoiceOver 运行时不自动消失。为出现事件发送 accessibility announcement。 | `DetailCardMenu.swift:221-257` |

## 翻译元素与状态

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 页面翻译 toolbar | target 非 off 且非日语时出现；`.translating/.downloading` 显示带 a11y label 的 `ProgressView`，其余为“翻译/显示原文” button | **保留。** 入口与状态映射明确；spinner 有辅助名称。 | 下载和翻译可以使用不同可见状态文案，避免只有 VoiceOver 用户知道正在做什么；若工作可能较久，在页面内加入可见进度行。 | `LiveDetailView.swift:151-179` |
| 翻译启动和 retry 幂等 | `startPageTranslation()` 先检查 availability；仅在未显示时 toggle on；提交当前 event id 的全部 page segments | **保留。** retry 不会意外把翻译关掉，event scope 也显式传递。 | 保持。下载前如系统 Translation API 会弹系统 UI，无需额外自制确认。 | `LiveDetailView.swift:181-195` |
| 卡片翻译 menu | 只有提供 `translationSegments` 且 target 可翻译时出现；按 card key toggle；首次开启提交 card segments | **保留。** 次级功能放 menu，作用域明确。 | menu 文案可加卡片名的 accessibility hint；不要把常用主任务挤到卡片 header。 | `DetailCardMenu.swift:152-166` |
| `OfficialText` | 按 page/card toggle 从 cache 取译文，否则回退原文；`Text(verbatim:)`；opacity content transition + Reduce Motion aware animation | **保留。** 官方文本不误入 app localization；缓存缺失时仍可读，动画克制。 | 混合命中时可能一部分译文、一部分原文；如果常发生，应在 attribution 说明“部分内容可能保留原文”，不要用颜色区分每一段。 | `DetailCardMenu.swift:260-286` |
| `OfficialTextList` | 每个 value 独立查缓存后 join，单个 `Text` 自然换行；同样使用 opacity transition | **保留。** 适合出演者/会场短列表，避免多个 chip 增加噪声。 | 对非常长的 performer 列表可改语义 list；当前没有 line limit，不存在代码层截断。 | `DetailCardMenu.swift:288-317` |
| 页面翻译归属 | 页面 toggle 开启时，在标题下显示 `Label(character.bubble)`、caption secondary：“Apple 本机翻译，非官方资料…” | **保留。** 来源和非官方属性显式可见。 | 可把归属放到 selectors 下方，使长标题和归属不被分开；caption 只是信息层级，不是交互命中问题。 | `LiveDetailView.swift:45-47`; `DetailCardMenu.swift:319-333` |
| 卡片翻译归属 | 卡片 menu 可以单独开启翻译，但 `DetailCard` 内容中没有依据 card key 渲染 attribution | **缺陷 · P1。** 用户可能看到卡片译文，却没有任何可见“本机翻译/非官方”归属；页面级 footer 仅检查 `cardKey: nil`。 | 在 `DetailCard` 内、内容底部条件显示精简 attribution，或由 `DetailCardMenu`/环境暴露 `isShowingCardTranslation`。不要依赖 menu 的当前勾选状态作为唯一披露。 | `LiveDetailView.swift:45-47`; `DetailCardMenu.swift:152-165`; `OverviewView.swift:315-334` |
| 翻译失败行 | 页面顶端 `TranslationFailureRow`：critical caption label + 条件“重试”按钮；unsupported 不显示 retry | **部分缺陷 · P1。** unsupported 行正确；但全局 phase 无法表达失败属于哪张卡，且 retry closure固定调用整页 `startPageTranslation()`。卡片翻译失败后会把用户导向整页翻译。 | `TranslationStore` 保存失败 request scope（page/card key + items）；失败行按 scope 放在对应页面或卡片，并重试原 request。若暂不改模型，至少把按钮改为“重试整页翻译”避免误导。 | `LiveDetailView.swift:48-54`; `DetailCardMenu.swift:152-165, 335-369` |
| 翻译不可用 alert | `Alert` 标题“翻译不可用”、单个 cancel“好”、message 来自 availability | **保留。** 阻塞性平台能力失败使用 alert 合理。 | message 应说明可行动的原因（目标语言不支持/系统版本/下载失败）；非阻塞网络错误继续使用 inline row。 | `LiveDetailView.swift:134-145, 181-195` |

## 概览分区

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 概览卡片排序 | `ImportantInformationPolicy.overviewCards` 生成顺序，`LazyVStack(spacing: 12)` 渲染；支持置顶、隐藏、撤销和全部恢复 | **保留。** 用户配置进入实际信息层级，稳定 id 不是数组下标。 | 用 UI 测试覆盖置顶+隐藏+场次切换组合；视觉保持当前 12pt 节奏。 | `OverviewView.swift:15-45` |
| 无场次状态 | `selectedPerformance == nil` 时每个 `cardView` 返回 `EmptyView` | **缺陷 · P1。** 整个概览会静默空白，没有原因和恢复路径。 | 在 `OverviewView.body` 顶层判断并显示 `ContentUnavailableView`，说明“尚无可用场次资料”，提供官方页面 Link；不要在每张卡重复空态。 | `OverviewView.swift:48-55` |
| 时间与会场卡 | `LabeledContent` 展示开场/开演；数字 monospaced；设备本地时间为 secondary footnote；会场用 `OfficialTextList`；字段可按配置隐藏 | **保留。** 标签和值语义清楚，时区派生明确，缺失时间/会场有文字状态。 | 大字号下渲染验证多个 `LabeledContent` 的 label/value 是否堆叠自然；系统控件本身支持 Dynamic Type，不预设为缺陷。 | `OverviewView.swift:87-139` |
| 出演卡 | 有值时 join 为一段可换行文字；空数组显示 secondary 文案 | **保留。** 空值不留空白，翻译 scope 正确。 | 出演者很多时，逗号串不利于扫读；只有真实数据常超过约 5–6 人时再改成 FlowLayout 或分行列表。 | `OverviewView.swift:141-160` |
| 票价卡主行 | 每 tier 为 `VStack`；内部固定 `HStack` 放名称、Spacer、价格；金额 monospaced；附加说明 footnote；非完整价格加图标+warning 色 | **调整/待验证 · P1。** 非完整票价不只靠颜色，语义正确；长票种名+价格在 AX 字号下可能竞争宽度。 | 用最长日文票种和 AX5 渲染。若价格被挤压或名称难读，改 `ViewThatFits`：常规横排、窄宽纵排且价格置于下一行 leading。 | `OverviewView.swift:162-213` |
| 票价适用范围提示 | 无场次 offer 时显示“官网公布票价，适用场次请核对…” caption secondary | **保留。** 明确数据范围，降低误用。 | 可加 info icon，但不是必要；不要提高为 warning，除非确有购错风险。 | `OverviewView.swift:173-181` |
| 入场条件卡 | 从 evidence 过滤 `event.admission`；无 evidence 时显示“尚未获取或待核验，请从官方来源确认”；正文 subheadline | **保留。** 未知状态和恢复方向明确。 | 若有多条 evidence，增加 source/date 或 DisclosureGroup；当前只显示 quote，来源只能去历史 sheet 查，操作链较长。 | `OverviewView.swift:227-244` |

## 票务分区

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 分区定时刷新 | `TimelineView(.everyMinute)` 将当前时间传给状态解析 | **保留。** 开售/截止状态可自动更新，不需要用户刷新页面。 | 避免在每分钟触发昂贵网络工作；当前只重算展示，合适。 | `TicketsView.swift:22-26` |
| 售票顺序 | open、upcoming 直接显示；closed、未确认 round 用 `DisclosureGroup`；然后特典、配信、AI links | **保留排序，调整分组 · P1。** 主动售票优先且过期资料折叠；特典大图和配信仍与售票卡同一连续流，页面会很长。 | 增加可见 section header：“受付”“特典”“配信”“AI 识别链接”；特典媒体默认 compact 或折叠。主 CTA 和截止时间应在首屏可扫到。 | `TicketsView.swift:45-95` |
| 票务空状态 | 当 round/benefit/stream/assistant links 均为空且 hiddenCount 为 0 时，`LazyVStack` 不产生任何内容 | **缺陷 · P1。** 用户看到空白分区，无法区分无资料、场次不适用或加载失败。 | 计算 `hasVisibleTicketContent`；为空时显示 `ContentUnavailableView`，区分“所选场次暂无票务”与“卡片已全部隐藏”，并提供官方页/恢复显示动作。 | `TicketsView.swift:29-116` |
| 配信卡 | `DetailCard` + `LabeledContent` 平台/费用/三个时间；region footnote；根据 scope/status 切换“前往官方配信/查看官方来源” | **保留/调整 · P2。** 数据和值结构清楚；主配信 Link 没有 prominent style，开放配信与只读来源视觉差异主要靠文案。 | actionsAllowed 时用 `Label(play.rectangle)` + borderedProminent；只读来源保持普通 Link。渲染验证多日期 LabeledContent。 | `TicketsView.swift:118-145` |
| 售票 round 卡标题 | 官方 name 作为 verbatim headline；卡 menu 支持刷新/置顶/密度/翻译/隐藏 | **保留。** 官方名称不会误本地化，翻译 segment 包括名称和 notes。 | 若标题本身已是裸 URL 或过长营销句，应在数据层提供短 display label；UI 不应硬截断官方名。 | `TicketsView.swift:148-171` |
| scope/type/status | scope 用 caption2 secondary/orange 文本；type 为 footnote；status 用 caption semibold `Label` + 颜色 18% capsule | **保留语义，调整层级 · P2。** status 具图标、文字、形状，不只靠颜色；scope/type 分散成三行，增加卡头高度。 | 合并成一行可换行的 metadata FlowLayout：status 优先，type/scope 次级；caption2 本身会随 Dynamic Type 缩放，但其视觉权重需实测。 | `TicketsView.swift:171-177, 277-293, 417-429` |
| 受付、资格、结果、入金信息 | 多个条件 `Text`，大多 footnote；无时间窗口时使用状态化 fallback | **调整 · P1。** 数据完整，但关键截止与次级资格平铺同权，主任务不易扫读。 | 将“销售状态 + 截止时间 + 申请 CTA”固定放在卡首；资格、当落、入金放 DisclosureGroup“申请详情”。不要仅靠 compact density隐藏业务关键项。 | `TicketsView.swift:179-208` |
| 抽选商品映射 | 每商品 `VStack`；名称可选择；copy icon button；下面分别显示商品对应申请链接和对象商品链接；多商品有“复制全部” | **保留方向，待验证 · P2。** 商品到申请入口的关联比全卡混列清楚；copy icon 有 accessibility label。固定 HStack 在长商品名下需检查。 | copy button 保持至少 44pt 可触区域；当前 `.buttonStyle(.borderless)` 没显式 frame，不能从源码断言实际命中大小，应在 Accessibility Inspector 测量。可给复制完成 sensory/文本反馈。 | `TicketsView.swift:323-357` |
| 官方申请链接 | `round.unassignedApplicationLinks` 在 details 前显示；商品专属申请链接跟随商品；`OfficialLinksView(prominentFirst: officialActionsAllowed)` 可突出首项 | **保留。** CTA 更靠近对应对象，减少错链；开放期首项可突出。 | 如果同一商品有多个 vendor，不能只把第一项 prominent 而暗示其唯一性；显示渠道/地区标签或保持同等级。 | `TicketsView.swift:209-210, 323-344`; `OfficialLinksView.swift:21-46` |
| 重要 notes | caption section 标题；每条 `Label(kind icon)` + translated footnote；notes links 固定 `HStack` 内 bordered Links | **调整/待验证 · P1。** icon+文字语义清楚；多链接和 AX 字号下固定 HStack 无 fallback。 | 将 link HStack 换 `FlowLayout` 或纵向列表；保留系统 Link 的 Dynamic Type，不缩小字体。将影响入场资格的 note 提前到 CTA 前。 | `TicketsView.swift:359-386` |
| 价格 rows | 每 offer/tier 用 `LabeledContent`，价格 monospaced，缺失显示“价格待核验” | **保留/待验证。** 标准键值控件语义正确；长 tier 名需要渲染确认。 | 在 AX5 下测试；若 label/value 竞争，让价格另起一行而非 lineLimit。 | `TicketsView.swift:213-223` |
| 截止提醒 | 仅 actionable 且 open/upcoming 时出现 bordered `Button`；无未来 deadline 时 disabled；结果 caption 就地显示 | **保留/调整 · P2。** 可用性条件完整，避免无意义提醒。 | disabled 时若仍显示，应提供 accessibility hint“缺少未来截止时间”；反馈像顶部刷新一样区分成功/失败。 | `TicketsView.swift:225-245, 260-275, 450-453, 496-540` |
| 已申请/已付款 | 两个原生 `Toggle`，按 `ViewThatFits` 在 HStack/VStack 切换；整体 `.font(.footnote)` | **保留/待验证。** 原生 Toggle 有系统状态和可访问性，不能因 footnote 就判命中小；fallback 能适配宽度。 | 在 compact 卡+AX5 下验证 toggle label 与 switch 是否完整；考虑 section label“我的进度”，提高可发现性。 | `TicketsView.swift:237-258` |
| 特典卡 | status/detail/notes、适用票种、领取地点/时间、media、官方 links 全在 DetailCard；TBA/缺失用文字+warning 色 | **保留状态，调整密度 · P1。** 未公布和缺失状态不留白；大图位于长卡中，会显著拉长票务任务流。 | media 默认显示缩略图高度并把“查看特典图片”作为 disclosure；将特典 section 放在所有 open/upcoming round 之后并明确标题。 | `TicketsView.swift:544-612` |
| 特典 placeholder | 无特典记录但存在 goods-bundled tier 时生成 placeholder card，列出票种和价格 | **保留。** 区分“官网明确待公布”和“页面未描述”，避免误推断。 | 标题混用日文“グッズ付き”，若产品主要中文，应保留官方词同时补中文括注。 | `TicketsView.swift:614-640` |

## 周边分区

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 周边 section 标题 | 现场/通贩/其他按 policy 分组；`.title3.bold()`、leading、`.isHeader`；未确认资料另有 subheadline 标题 | **保留。** 分类和 header 语义能改善长页面扫描。 | 未确认 section 也增加 `.isHeader`，并用图标/说明而非仅 secondary 层级。 | `GoodsView.swift:19-29, 73-82` |
| 周边空状态 | 区分“没有资料”和“卡片全部隐藏”；后者有说明与恢复按钮 | **保留。** 是四个分区中空状态实现最完整的页面。 | “没有资料”也增加官方页入口，给用户下一步；系统 `ContentUnavailableView` 保持。 | `GoodsView.swift:31-49` |
| campaign 卡元数据 | phase caption；销售/领取时间和地点使用 `LabeledContent`；detailed 才显示 sessions、配送、付款方式 | **保留/调整 · P2。** 字段开关和密度确实控制信息量；但 campaign 卡仍可能很长。 | 将配送/付款/购买限制组合到“购买须知” DisclosureGroup；保留时间和地点常驻。 | `GoodsView.swift:84-128` |
| 商品主行 | 产品名、Spacer、价格固定 HStack；价格 monospaced secondary | **待验证 · P1。** 结构便于常规字号扫读；长日文产品名与价格在大字号下可能竞争宽度。 | 用最长真实名称+AX5 渲染；失败时用 `ViewThatFits` 横排/纵排。不要给名称 lineLimit 或缩字。 | `GoodsView.swift:151-160` |
| 商品变体行 | bullet、名称 footnote、Spacer、stock caption、金额 footnote置于同一 HStack | **调整/待验证 · P1。** 一行同时承载四种内容，最容易在长名称和大字号下变得拥挤。 | 每变体改为 `Grid` 或 `ViewThatFits`：名称一行，库存与金额为次行；库存状态除原文外如有规范状态可配 icon。 | `GoodsView.swift:161-172` |
| 商品/贩售链接 | 商品 Link 使用 footnote；campaign 用 `OfficialLinksView`，可突出首项；若 campaign.url 未在 links 中则另加 Link | **调整 · P2。** 数据去重存在，但主销售入口可能分散成 link list、商品 link、fallback link。 | 每 campaign 只保留一个首要“前往官方销售”区域，商品 links 作为次级；对来源型只读链接统一样式。 | `GoodsView.swift:130-146, 174-176` |
| campaign 媒体 | 过滤 goods list/notice/area map/product assets，逐个嵌入 `OfficialMediaView`；compact 跟随卡密度 | **调整 · P2。** 官方图有价值，但多个图连续嵌入会把商品和 CTA推远。 | 多于一张时显示首张缩略图+“查看全部 n 张”；或使用横向 gallery，避免多个 340pt 高媒体纵向堆叠。 | `GoodsView.swift:140-142, 180-183` |
| AI 周边链接 | 有 summary 时附加 `AssistantLinksSection`，内部只显示适用 selected performance 的 links | **保留/调整 · P2。** 与官方抓取链接来源区分；但置于空状态之后时，页面可能同时说“尚未获取周边资料”又显示 AI links。 | 空状态判定应把 applicable assistant links 纳入：有 AI link 时改成“暂无结构化周边资料”，避免自相矛盾。 | `GoodsView.swift:31-53`; `AssistantLinksSection.swift:18-35` |

## 座位分区

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 座位资产排序 | applicable 与 unconfirmed 分开，经 policy 排序；适用资产先显示 | **保留。** 确认资料优先，未确认资料不会混入主列表。 | 保持。 | `SeatingView.swift:12-31` |
| 未确认 section | subheadline secondary 标题；每张卡再显示 orange caption“适用场次待确认” | **保留语义，调整层级 · P2。** 文字明确，不只靠橙色；但卡片外和卡片内重复。 | section 标题保留，卡内改 status `Label(questionmark.circle)` 或仅在卡片可脱离 section 重用时保留。 | `SeatingView.swift:27-30, 57-66` |
| 座位空状态 | 区分完全无资料和全部隐藏；隐藏态提供恢复按钮 | **保留。** 状态判断没有把隐藏误报为未获取。 | 完全无资料时增加官方 venue/event 页入口。 | `SeatingView.swift:33-49` |
| 场馆通用图警告 | caption orange 文本“场馆通用图，不代表本次舞台布局” | **保留语义，调整 · P2。** 文本已说明风险，不依赖颜色。 | 改为 `Label(exclamationmark.triangle)`，并使用 semantic warning 色而非 `.orange`，与其他状态一致。 | `SeatingView.swift:54-65` |
| 座位媒体 | `OfficialMediaView`，compact 随 card density | **保留。** 图片可进入全屏缩放，适合座位图核心任务。 | 对座位图优先保留 detailed 预览高度；compact 可以只限制卡内高度，不应降低全屏清晰度，当前实现符合。 | `SeatingView.swift:54-67`; `OfficialMediaView.swift:118-127, 238-255` |

## 官方链接与 AI 识别链接

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 官方链接分组标题 | caption secondary `Text`；空数组不渲染；可排除已展示 URL | **保留。** 可复用且能去重，次级 section 标题权重合适。 | 若链接组是卡片主 CTA（官方申请/销售），标题可提升为 subheadline semibold；普通来源组保持 caption。 | `OfficialLinksView.swift:16-25` |
| 官方链接按钮 | 每个 URL 为 `Label(text, arrow.up.right.square)`；首项可 borderedProminent，其余 bordered；下方 caption2 host | **保留/调整 · P2。** 系统 Link 和 button styles 自带交互/字体行为；多个 bordered button 纵向堆叠可能与主 CTA竞争。 | prominent 只用于确实首选且可执行的链接；来源/支持链接改 plain row 或单一 DisclosureGroup。host 改为辅助 accessibility value 或保持可见但不重复裸域名。 | `OfficialLinksView.swift:21-46` |
| 官方链接翻译 | 提供 cardKey/eventID 时，link label 使用 `OfficialText`；否则 verbatim | **保留。** 官方 label 不误本地化，卡片翻译可覆盖。 | 翻译后的 link label仍应保留原 host，当前做到；可给 accessibility hint说明将打开外部网站。 | `OfficialLinksView.swift:50-58` |
| AI links 容器 | headline 标题、caption 来源披露、每行全宽 `Link`；16pt padding + secondary rounded card | **保留来源披露，调整卡层级 · P2。** AI link与官方抓取卡明确分开；在卡片页面再加一张同样背景卡会增加表面层数。 | 在 Tickets/Goods 页面作为普通 section 而非额外圆角卡，或把所有 AI links放入单个 DisclosureGroup。 | `AssistantLinksSection.swift:22-35` |
| AI link row | `Link` label 内 HStack：bold label + kind capsule、note footnote、host caption2、trailing external icon；icon a11y hidden，整行 contentShape，浏览器 hint | **保留/待验证。** 整行可点、辅助 hint完整；label+badge 固定内层 HStack在长文案下需渲染。 | 对 label/badge 使用 FlowLayout 或 `ViewThatFits`；不要给 label lineLimit。确认 VoiceOver 朗读 kind badge与 label不会重复/顺序混乱。 | `AssistantLinksSection.swift:38-73` |

## 官方媒体与全屏查看

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 媒体类型分流 | `asset.isImage` 时加载图片，否则只渲染原始 Link，不自动 fetch；`.task(id: previewTaskID)` 响应版本/URL变化 | **保留。** 非图片不会误当图片下载，task identity完整。 | 保持。 | `OfficialMediaView.swift:61-95, 201-210` |
| 图片预览按钮 | plain `Button` 包含 quaternary 圆角底、resizable/scaledToFit UIImage、4pt padding；比例取实际图或 16:9；maxHeight compact 160 / detailed 340；无图 disabled | **保留/调整 · P2。** 整张图是大触控面，a11y label/hint明确；视觉上没有放大图标，触控可发现性依赖用户习惯。 | 图片右下角增加不抢内容的 `arrow.up.left.and.arrow.down.right` badge，或 caption旁写“轻点查看原图”；不要覆盖座位图关键区域。 | `OfficialMediaView.swift:98-127` |
| 预览 loading | 图片区域中央 `ProgressView`；成功 opacity transition并通过 motionAnimation适配 Reduce Motion | **保留。** 空间稳定且状态就地。 | 加载超过约 1 秒时再显示“正在载入”，避免即时加载闪文字。 | `OfficialMediaView.swift:105-120, 149-150` |
| 预览错误与重试 | ZStack overlay：warning Label + bordered small “重试”；错误区域同预览最大高度 | **保留恢复路径/待验证命中 · P1。** 有明确重试。`.controlSize(.small)` 表示视觉和系统 control metrics更紧凑，但仅凭源码不宣称命中区不足。 | 在 Accessibility Inspector 测量重试按钮；若小于 44pt，外加 `.frame(minWidth: 44, minHeight: 44)`。长错误文案在 compact 160pt 内需 AX5 渲染验证。 | `OfficialMediaView.swift:129-148` |
| 图片 caption | footnote secondary，多行默认，无 line limit | **保留。** 作为媒体说明层级合适，系统字体会缩放。 | caption若是关键座位说明，不应 secondary；由 asset kind决定语义，不宜全局改。 | `OfficialMediaView.swift:152-156` |
| 卡内分享/浏览器/host | 成功后显示 `ShareLink`、普通 Link和 caption2 host，全部纵向常驻 | **调整 · P2。** 功能完整但次级动作增加每张媒体卡高度。 | 合并成 `Menu`（分享、浏览器打开、查看来源），或只保留一个“更多”按钮；座位图可保留分享直达。 | `OfficialMediaView.swift:158-175` |
| 非图片/非法 URL | 有 URL时显示可选择的绝对 URL Link；无效时 secondary caption原字符串 | **调整 · P2。** 能保留证据，但裸 URL 很长，信息层级差。 | 以 host +“打开官方附件”作为 label，把完整 URL留给 accessibility value/上下文菜单复制；无效 URL显示“链接格式无效”及截短值。 | `OfficialMediaView.swift:179-199` |
| 全屏 presentation | `.fullScreenCover` 创建 `ZoomableImageViewer`；内部 `NavigationStack + black ZStack`，成功显示 UIKit zoom view，loading和error各有状态 | **保留。** 媒体沉浸式查看使用全屏正确，状态分支清楚。 | 保持黑色背景；旋转、safe area和 iPad多任务需实测。 | `OfficialMediaView.swift:91-95, 241-277` |
| 全屏失败 | `ContentUnavailableView` 显示图片 icon和错误文案，但无 action | **缺陷 · P1。** 卡内有重试，全屏失败却没有恢复入口，只能关闭。 | 在 `ContentUnavailableView` actions 中增加“重试”和“在浏览器打开”；重试调用 `loadImage()`。 | `OfficialMediaView.swift:261-268, 320-331` |
| 全屏底部资料 | `safeAreaInset(.bottom)` 常驻 caption、完整 image URL、可选 source URL；padding + thinMaterial | **调整 · P2。** 来源透明，但长 URL长期占据媒体面积，尤其大字号下明显。 | 默认显示 caption + host；完整 URL和第二来源放 DisclosureGroup或 toolbar menu。需要保留可复制能力。 | `OfficialMediaView.swift:278-293` |
| 全屏 toolbar | cancellationAction“关闭”；有 image时 primaryAction ShareLink；深色 toolbar scheme；均有 accessibility identifiers | **保留。** 关闭与分享是全屏查看最需要的两个动作，位置符合平台惯例。 | iPad上验证 ShareLink popover锚点；无需自定义悬浮按钮。 | `OfficialMediaView.swift:294-317` |
| UIKit zoom surface | `UIViewRepresentable` 包装 `UIScrollView`；min/max zoom 1/6，bounce，隐藏 indicators，aspectFit UIImageView；double tap切换 1x/3x；旋转/size变化重排 | **保留。** UIKit是此处合理选择，捏合/双击/居中实现完整。 | `minimumZoomScale = 1` 实际代表 fit scale后的基准，命名行为合理。需真机测试超长图、超宽图和旋转后焦点。 | `OfficialMediaView.swift:352-463` |
| VoiceOver zoom | UIScrollView作为单一 image accessibility element，label来自 caption；自定义“放大/缩小/重置”actions | **保留，补缺 · P1。** 自定义动作提供手势替代；若 caption为 nil，UIKit accessibility label也会是 nil。 | `setImage` 中为 nil/空 caption提供“官方图片/座位图”等 fallback label；可把当前 zoom percentage作为 accessibility value。 | `OfficialMediaView.swift:383-389, 412-418, 464-477` |

## AssistantSummaryCard 与富文本

| 元素 | SwiftUI/UIKit 具体实现、参数与状态 | 评价 | 精确建议 | 位置 |
|---|---|---|---|---|
| 卡片状态机 | `CardPhase` 覆盖 notSignedIn、empty、generating(previous)、ready、failed(previous,message)；生成/错误优先于账号状态 | **保留。** 状态集中、互斥，旧摘要可在刷新/失败时保留；比散落条件更可靠。 | 给 phase transition 做 UI tests：生成中退出登录、失败且有旧摘要、删除后 empty/notSignedIn。 | `AssistantSummaryCard.swift:21-52, 69-97` |
| 卡片整体 | 复用 `DetailCard(.assistantSummary)`；有 accessibility identifier；删除确认用 `confirmationDialog`，destructive与cancel齐全，并说明只删除 AI 结果 | **保留。** 高影响操作有具体对象和后果，官方资料边界清楚。 | 确认删除成功后发 accessibility announcement；dialog文案保持。 | `AssistantSummaryCard.swift:54-67` |
| 未登录状态 | secondary说明 + `NavigationLink` 到 Assistant Settings，label带 person badge icon | **保留。** 解释前置条件并提供直接恢复路径。 | 如果用户配置 API key 与 ChatGPT 两种方式，设置页目标应定位到账号 section；不必在卡片重复两按钮。 | `AssistantSummaryCard.swift:99-114` |
| 空状态 | 只有“用 AI 整理本公演”按钮和 sparkles icon | **调整 · P2。** 动作直达，但没有说明会发送什么、结果保存位置或非官方属性；相比未登录态信息不足。 | 加一句短说明：“整理官网资料并保存到本机；结果非官方”，避免按钮成为无上下文的生成动作。 | `AssistantSummaryCard.swift:116-129` |
| 生成中状态 | HStack label + pulse symbol + cancel small bordered button；有旧摘要时以 0.5 opacity显示并 disabled | **保留/待验证 · P2。** 能取消且保留上下文；pulse由外层 motionAnimation并不控制 symbolEffect是否遵守 Reduce Motion，需实测。 | 读取 `accessibilityReduceMotion`，开启时取消 `.symbolEffect(.pulse)`；Accessibility Inspector测量 small取消按钮命中区，不从代码直接断言。 | `AssistantSummaryCard.swift:131-157` |
| 失败状态 | critical Label；有旧摘要时 0.5 opacity显示，无旧摘要时显示 actionsRow | **调整 · P1。** 错误可感知，但有旧摘要时 actionsRow仍在 `summaryContent` 末尾且整体半透明，重试入口视觉也被弱化。 | error banner旁加明确“重试”button，不把恢复动作跟随旧摘要一起降 opacity；旧摘要标记“上次结果”。 | `AssistantSummaryCard.swift:159-181` |
| ready信息顺序 | header → overview →本场摘要/highlights→重点→warnings→整理字段→actions→删除 | **调整 · P1。** 内容完整，但高优先级 warnings和当前场次重点位于长 overview之后；“AI整理字段”进一步增加卡高。 | 顺序改为 stale/warnings → 当前场次 high重点 → overview →更多字段 DisclosureGroup→actions。compact状态默认只显示高优先点的方向保留。 | `AssistantSummaryCard.swift:183-223` |
| 生成元数据与 stale | 两行 caption secondary：“已保存到本机”、模型/时间/非官方；stale为 secondary Label + refresh icon | **调整 · P1。** 来源透明；stale会影响决策却与普通元数据同一低权重。 | stale使用 warning semantic background或至少 `.statusWarning` + semibold，并紧邻“重新整理”动作；仍保留“非官方”说明。 | `AssistantSummaryCard.swift:293-311` |
| 本场摘要与 highlights | detailed density才显示；headline“本场(dayLabel)”；summary body；highlights用 bullet HStack并合并 accessibility element | **保留。** 当前场次 scope明确，bullet对VoiceOver隐藏并合并朗读。 | highlights 很多时限制首3条并 disclosure；不要用 lineLimit截断单条。 | `AssistantSummaryCard.swift:191-203` |
| 重点 rows | headline section；compact只显示 high，按钮展开全部；每行有importance/category symbol、high胶囊、category caption2和RichText；显式组合 accessibility label | **保留语义，调整布局 · P2。** 重要性不靠颜色且朗读文本完整。内层 category HStack 在超长本地化下需渲染。 | category metadata改 FlowLayout或允许垂直排列；“展开全部”可保持系统 Button，caption字体不代表命中区，实际触区需 inspector验证。 | `AssistantSummaryCard.swift:313-367` |
| warnings | 前两条展开，其余 DisclosureGroup；warning icon + caption + semantic warning 色 | **保留渐进披露，调整层级 · P1。** 不只靠颜色；但 warnings在 overview和key points之后。 | 整段前移；rest内部每条也配 warning icon或合并可访问性前缀，保持与前两条一致。 | `AssistantSummaryCard.swift:260-291` |
| AI 整理字段 | 过滤当前场次；按 section 分 `DisclosureGroup`；field label caption secondary、value subheadline可选择；组合accessibility | **保留。** 大量结构化内容默认折叠，适合渐进披露。 | 整个“AI 整理字段”可以再做总 DisclosureGroup，避免多个section disclosure仍占较多高度；字段空值应不渲染或明确“未公布”。 | `AssistantSummaryCard.swift:225-258` |
| 底部动作 | `ViewThatFits` 横排/纵排；bordered、small、footnote；“重新整理”disabled于生成中或未登录；官方 Link带图标 | **保留自适应，待验证命中 · P2。** ViewThatFits能适配宽度，系统控件支持Dynamic Type；small只证明更紧凑，不自动证明触区不合格。 | Inspector测量按钮；若小于44pt，增加 min frame而不放大文字。stale时将“重新整理”提升为 prominent，平时保持 bordered。 | `AssistantSummaryCard.swift:369-411` |
| 删除按钮 | destructive role、trash Label、footnote；仅已有 summary时显示，点击后确认 | **保留角色，调整位置 · P2。** 删除常驻卡底会与日常动作竞争。 | 移入卡片 menu或“更多” DisclosureGroup；保留 confirmationDialog。 | `AssistantSummaryCard.swift:211-221, 54-67` |
| 富文本普通/粗体/重要 | `AttributedString`：bold用 stronglyEmphasized；important同时 stronglyEmphasized + semantic critical色 | **保留。** important不只靠颜色。 | 确认 critical色在浅/深/增强对比下达标；无需再加背景到每个词。 | `AssistantRichTextView.swift:3-20` |
| 日期/价格 rich segment | date设 primary + `.body.monospacedDigit()`；price strong + primary | **保留。** 日期不误用link蓝色，金额靠字重不靠绿色，数字易扫读。 | 外层 `AssistantRichTextView(font:)` 传入非body时，segment自己的 `.body` font可能覆盖外层字体，需写一个 unit/render test确认；必要时只设 number spacing而不固定body。 | `AssistantRichTextView.swift:21-29, 51-65` |
| warning rich segment | 在每个 warning segment前插入“⚠︎ ”并使用 warning色；正文也warning色 | **保留语义/待验证。** 有符号替代色彩；多个连续 warning segment可能重复符号。 | parser层合并连续 warning segment，或 renderer仅在从非warning切到warning时插符号；用VoiceOver检查字符朗读是否自然。 | `AssistantRichTextView.swift:29-34` |
| link rich segment | 合法URL时 underline + accent + `AttributedString.link`；无效URL fallback strong | **保留。** 可交互链接具有 underline，不只靠蓝色；无效URL仍有视觉强调。 | 为外链增加 accessibility hint由系统 Text link通常已提供，先实测再补，避免重复朗读。 | `AssistantRichTextView.swift:34-41` |
| RichText渲染容器 | 单个 `Text(attributed)`，可选择，`fixedSize(horizontal:false, vertical:true)`，默认body且允许调用者传Font | **保留。** 无line limit，文本可纵向增长；可选择适合AI/官方信息核对。 | 长摘要会完整展开造成卡过长，应在内容组织层做 DisclosureGroup，不在 Text层截断。 | `AssistantRichTextView.swift:49-65` |

## 明确优先级

1. **P1 确定缺陷**：补票务空状态；补概览无场次空状态；让卡片翻译显示归属；卡片翻译失败必须重试原卡片请求；全屏媒体失败增加重试；无 caption 的缩放图补 accessibility label。
2. **P1 信息层级**：critical notices前移；票务卡首固定状态/截止/主申请入口；AI warnings、stale和当前场次高优重点前移。
3. **P1 渲染验证**：四项 segmented picker、票价/商品/变体固定 HStack、notes多链接、图片错误 overlay、所有 `.controlSize(.small)` 交互在 AX3–AX5 和 320pt宽度下检查。只有测量失败后才判为缺陷。
4. **P2 密度**：把票务特典/配信、周边多媒体、官方支持链接、AI整理字段和媒体次级动作放入清晰 section或DisclosureGroup，减少同权卡片与常驻链接。

## 建议验证矩阵

| 场景 | 需要确认的元素 |
|---|---|
| iPhone SE / 320pt、默认字号 | pinned selectors、四项 segmented picker、长官方标题、toolbar三项、票价/商品横排 |
| iPhone常规宽度、AX3与AX5 | FlowLayout动作、场次chips、LabeledContent、notes links、small controls实际命中区、媒体错误overlay |
| iPad 1/3 split view与横屏 | pinned header、fullScreenCover、ShareLink popover、媒体底部safe-area inset |
| VoiceOver | 场次选中态、卡片menu超长label、隐藏/撤销announcement、AI key point组合朗读、RichText warning符号、zoom自定义actions与无caption图片 |
| Reduce Motion | tab/翻译opacity变化、场次自动滚动、AI pulse symbol是否停止 |
| 浅色/深色/Increase Contrast | secondary card背景、critical notice 14%背景、status capsule、AI warning/importance语义色、thinMaterial媒体footer |

本文件仅记录当前代码证据与建议，没有修改任何产品实现。需要渲染验证的项目不能被视为已经失败，也不能据此声称达到或违反完整Apple HIG合规。
