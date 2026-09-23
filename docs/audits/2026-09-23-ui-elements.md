# UI 元素实现方式审查

本轮针对 2026-09-23 当前工作区重新读码，评价具体 UI 元素的控件选择、布局参数、状态绑定、反馈、可访问性与实现建议。没有修改产品代码，没有进行新的运行时 UI 验证。重复使用的元素按实现合并，业务变体另列；不把每个重复 Text 实例当作不同组件。

完整报告由三份组成：

- 本文件：应用壳、演出/往期、筛选、我的、共享布局、字体与颜色，以及实施优先级。
- [详情与媒体、AI 元素](/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-23-ui-elements-detail.md)：详情框架、四个分区、卡片菜单、翻译、图片缩放与分享、AI 摘要和富文本。
- [设置与后台元素](/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-23-ui-elements-settings-admin.md)：设置表单、卡片设置、账号/模型/高级连接、对话框及后台 HTML 元素。

**结论类型**：保留＝控件与任务相符；调整＝体验/实现可以更直接；缺陷＝代码存在可说明的状态或行为问题；待验证＝需实际渲染/辅助技术验证，不能只凭字号或框架名称下结论。

**与上一轮的区别**：当前 `AppShell` 已向“我的”传入 router；`LiveEventCard.accessibilitySummary` 已包含 ticketBadges 和价格；主页导航标题已是 inline；单卡刷新已使用 `cardRefreshSucceeded` 区分成功与失败颜色。这些不再列为现存缺陷。旧报告是当时快照，不应直接作为本轮待办。

## 1. 应用导航元素

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 四个一级入口 | `TabView(selection: $router.selectedRootTab)`，四个具稳定枚举 value 的 `Tab`，每项是文字 + SF Symbol | **保留**。同级目的地应使用系统 Tab；不要另做浮动胶囊覆盖系统导航。iPad 是否需要 sidebar 取决于实际宽屏任务，不能仅凭平台强行替换 | [AppShell:102](/Users/sager/Documents/GitHub/live-dashboard/ios/LiveDashboard/LiveDashboardApp.swift:102) |
| 页面导航栈 | 演出、往期和我的分别拥有 `NavigationStack(path:)`；`DetailRoute` 记录公演/场次/分区 | **保留**。不同入口保留各自浏览路径。详情用 `.id(route)` 按路线重建，需接受重新进入时局部滚动/展开状态重置的行为 | [Dashboard:34](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:34) |
| 详情不可用占位 | `navigationDestination` 找不到缓存时显示 `ContentUnavailableView` | **调整**。控件合适，但只有描述；增加“重新检查资料”或明确返回入口，并区分仍在加载与确实缺失 | [Dashboard:110](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:110) |
| “我的”跨 Tab 入口 | `Button` 修改共享 router 的 selectedRootTab，当前 AppShell 已注入 router | **保留**。上轮缺少注入已解决；构造器保留 nil 默认值时，其他调用处仍可能没有动作，应决定这是必要依赖还是可选展示 | [AppShell:114](/Users/sager/Documents/GitHub/live-dashboard/ios/LiveDashboard/LiveDashboardApp.swift:114) |

## 2. 演出与往期：容器、工具栏、筛选栏

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 卡片网格 | `ScrollView` 内 `LazyVGrid`，adaptive minimum 340 / maximum 520，列间距与行距 16，外层 `.padding()` | **待验证/调整**。340pt 最小宽度与外边距对窄窗口不友好；大字体多列也可能过密。宽度不足时明确一列 `.flexible()`；大字体优先一列，宽屏再根据实际容器计算列数。无需把全部布局改成 GeometryReader | [Dashboard:36](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:36) |
| 整卡点击区域 | 外层 `NavigationLink(value:)` + `.buttonStyle(.plain)`，内部不是嵌套 Button | **保留，命中区待验证**。导航语义正确。若卡片空白不响应，在 label 的完整边界上明确 `.contentShape(.rect)`；检查 plain 样式的按下反馈，必要时只加轻微 opacity/背景变化 | [Dashboard:38](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:38) |
| 单公演刷新 | `contextMenu` 内 `Button` 启动 `Task`；全量或本卡刷新时禁用 | **保留**为次级操作。菜单中有文字与 SF Symbol，适合低频动作。若要求高可发现性，应在详情更多菜单也提供同义入口，无需再让封面点击承担刷新 | [Dashboard:42](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:42) |
| 封面分享 | contextMenu 内 `ShareLink` 使用 `OfficialImageTransfer` 与 `SharePreview` | **保留**系统分享链路。菜单分享与整卡跳转不冲突；“封面” identifier 应与“整卡” identifier 分开命名，而不是假装内部图像仍有独立 AX 节点 | [Dashboard:55](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:55) |
| 页面标题 | 系统 `navigationTitle` + `.navigationBarTitleDisplayMode(.inline)` | **保留**。当前已减少大标题占用；不再依据旧截图评价其首屏高度 | [Dashboard:101](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:101) |
| 搜索框 | `.searchable(text: filters.searchText, prompt:)`，Binding 写回按 scope 区分的 store filters | **保留**。系统清除、键盘与搜索语义合适。数据在内存过滤，无证据要求增加 debounce；只有性能测量显示卡顿才加节流 | [Dashboard:103](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:103) |
| 全量刷新按钮 | toolbar `Button`；进行中 label 换成 small `ProgressView`，带读屏说明，按钮禁用 | **保留**。这是动作，不应改 Toggle。small spinner 不等于按钮命中区很小；检查工具栏按钮实际边界。只在进度有数据依据时加百分比 | [Dashboard:117](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:117) |
| 筛选按钮 | toolbar `Button`，条件生效时切换 filled SF Symbol，附 `accessibilityValue` | **保留/调整**。非颜色唯一反馈已具备；当前 active 仅代表弹层条件，不代表年/月/搜索。给弹层筛选增加条件数，避免图标让人误以为所有筛选都为空 | [Dashboard:135](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:135) |
| 顶部筛选背景 | iOS 26 使用 `safeAreaBar`；旧系统 `safeAreaInset` + `.bar` material | **保留**。按系统版本提供背景与安全区处理，比绝对定位覆盖内容更合适。核对 Reduce Transparency 和滚动时的层级即可 | [FilterBarInset:339](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:339) |
| 年/月横竖切换 | `ViewThatFits(in: .horizontal)`，先 HStack，后 VStack；月份本身是横向 ScrollView | **待验证**。ViewThatFits 根据理想尺寸选第一个可容纳方案，不是大字体断点；可压缩的滚动视图可能继续留在很窄的横排里。若需求明确是辅助字号换行，直接按 `dynamicTypeSize.isAccessibilitySize` 选纵排；普通字号继续用尺寸回退 | [Dashboard:248](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:248) |
| 日历图标 | `Image(systemName:)`、secondary、`accessibilityHidden(true)` | **保留**。是辅助装饰，无需重复朗读，不需要 Button 命中区 | [Dashboard:272](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:272) |
| 年份菜单 | `Menu` 内多个修改年份的 `Button`；label 是单行 fixedSize Text + chevron，水平 padding 14、最小高度 44、Capsule 背景 | **调整**。这是单选值而非命令集合，推荐在 Menu 内使用绑定同一 selection 的 Picker，自动展示勾选项；保留外观。超长“全部年份”本地化需避免硬性 fixedSize 挤占月份 | [Dashboard:278](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:278) |
| 月份选项 | 泛型 `HorizontalSelectionStrip`，nil 代表全部，选项为可用月份与已选月份并集 | **保留**。稳定 value 身份与保留已选项很合理；需要清楚说明“未选择年份时，月份跨所有年份”这一筛选语义 | [Dashboard:300](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:300) |
| 上次更新时间 | `Text("更新于") + Text(date, style: .relative)`，caption2、secondary、额外 leading 16 | **调整**。时间现在会自动更新，优于一次性字符串；拼接句式对英语语序/空格不理想，应使用可本地化的完整句子或明确 label/value 两段。额外 leading 与父级叠加，检查是否需对齐首个控件而非无意缩进 | [Dashboard:238](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:238) |
| 下拉刷新 | `.refreshable { await store.refresh(); consumeDeepLink() }` | **保留**。使用系统刷新状态，任务真正 await 完成；不必做第二套下拉手势 | [Dashboard:159](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:159) |
| 有缓存时错误条 | bottom `safeAreaInset`，HStack 包含两行截断 Label、重试、关闭；regularMaterial | **调整**。安全区插入优于 overlay 遮住内容；长错误需要摘要+详情入口，重试/关闭应有明确最小命中区。辅助字号改纵向，使动作不挤压错误文本。重试运行中同步禁用/显示进度 | [Dashboard:71](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:71) |
| 加载与空状态 | overlay 内条件分支：加载、搜索无结果、刷新、往期为空、筛选为空、错误、尚未获取 | **保留/调整**。分类完整；首个无 label 的 ProgressView 可增加“正在载入资料”。当前搜索文本分支优先于错误/刷新，首次搜索遇网络失败可能只看到“无结果”，应先显示无缓存的加载/错误，再判断真正零结果 | [Dashboard:169](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:169) |

## 3. 演出卡片内部元素

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 卡片容器 | leading VStack spacing 6，默认 padding，secondary background，圆角 16 | **保留**基础结构。垂直间距 6 统一但不足以分隔信息组：标题/核心日期一组、状态/行动一组、补充资料一组，组间稍大，不必增加嵌套卡片 | [LiveEventCard:20](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:20) |
| 封面占位骨架 | 系统 fill 渐变占住 16:9；overlay GeometryReader 提供尺寸；圆角 12 | **保留**占位预留，可避免图片载入造成卡片跳高。渐变是占位而非装饰性 hero；GeometryReader 位于 overlay，不参与决定卡片固有高度，这一用法合理 | [LiveEventCard:268](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:268) |
| 图片裁切 | UIImage → resizable → scaledToFill → 固定容器尺寸 → 外层 clipShape | **调整/待验证**。适合统一缩略图，但会裁竖版文字海报。按内容选择统一 cover 裁切或 fit + 中性留边；不能仅换成 scaledToFit 就假定各种海报都美观 | [LiveEventCard:275](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:275) |
| 图片异步状态 | `@State UIImage?`，`.task(id: url)` 调用图片 pipeline，失败 try? 后直接 return | **缺陷**。同一公演封面由 A 改 B 时不先清空 A；B 失败仍保留 A，视觉上呈现旧封面。进入新 URL 任务时重置 image，或用包含 URL 的 phase 保证图片归属；取消后检查 Task 的做法应保留 | [LiveEventCard:292](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:292) |
| 无封面/载入失败占位 | 同一个 music.note + 团体文字，caption 单行 | **调整**。无图与加载失败目前不可区分。缩略图可以安静回退，但失败最好允许重试或随刷新重载；不需每卡堆错误面板。长团体名截断在占位中可接受，因为正文另有完整文字 | [LiveEventCard:300](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:300) |
| 企划与已关注 | HStack + Spacer，caption/secondary 与 caption/tint | **保留**为辅助元信息。已关注用文字而非仅星形颜色，有辨识度；它不是按钮，不要求 44pt | [LiveEventCard:25](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:25) |
| 单卡刷新指示 | small ProgressView，`accessibilityHidden(true)` | **调整**。视觉指示合适，但父级合并朗读未包含 `isRefreshing`。把“正在更新”加入 `accessibilityValue`，无需让每个 spinner 单独占一个读屏节点 | [LiveEventCard:30](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:30) |
| 官方标题 | `Text(verbatim:)` + headline + leading 多行，不限制行数 | **保留**原文与自然换行；标题很长使列表密度不均属于产品取舍，不是 SwiftUI 错误。若列表限制行数，应确保详情和朗读保留完整标题 | [LiveEventCard:46](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:46) |
| 公演状态徽章 | Label + SF Symbol，caption semibold，8/3 padding，浅背景 Capsule；结束中性，取消/延期 warning | **保留/调整**。状态文字与图标已避免纯颜色表达；取消可提高语义强调。徽章为静态标签，不应改成 Button | [LiveEventCard:189](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:189) |
| 售票阶段徽章 | `FlowLayout` 内 caption2 bold Text，8/3 padding，色背景 0.18，`.lineLimit(1)` | **调整**。FlowLayout 只能换“整个标签”，无法解除标签内部单行限制；长本地化与最大字号仍可能截断。允许标签内换行，或确保短标签词汇并在完整摘要中保留含义 | [LiveEventCard:229](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:229) |
| 团体名 | `Text(verbatim: joined(" × "))`，subheadline/secondary | **保留/调整**。可以自然换行；标题已含相同团体时可省略重复行。× 应只表达联合演出，若只是多个关联团体，列表分隔符更中性 | [LiveEventCard:55](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:55) |
| 日期/场数/站数 | 多段本地化字符串组合为一个 Text，subheadline | **保留**单文本换行，优于多个争空间的 HStack Text。单场日期格式只月/日，在跨年份“往期”中会失去年份，应在未限定年份时显示年 | [LiveEventCard:136](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:136) |
| 场馆 | `Text(verbatim:)` + subheadline/secondary | **保留**。多场馆长串可改“首站/共 N 场馆”，完整资料留详情，但不应靠缩小字号强塞 | [LiveEventCard:64](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:64) |
| 截止与最低价格 | `ViewThatFits` 横排/竖排复用 `deadlinePriceContent`，该内容含无条件 `Spacer(minLength: 8)` | **调整**。Spacer 在 HStack 横向伸展，在 VStack 会成为垂直空隙；无截止时也存在。抽出两个纯文字子视图，只在横排分支插 Spacer，纵排直接控制 spacing | [LiveEventCard:70](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:70) |
| 下一事项文字 | footnote/secondary，只显示日期截止；读屏额外包含 currentRoundLabel | **调整**。视觉与朗读提供的信息不一致。视觉也加入简短轮次/事项名，让用户知道是什么截止；临近状态有业务依据时再用强调色 | [LiveEventCard:115](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:115) |
| DAY 标签 | 去重后的 ForEach + FlowLayout，caption2，6/2 padding、quaternary Capsule | **保留**换行布局与稳定文本 ID；是静态元信息，不应仿照月份选择器做成可点击样式。场次很多时提供数量摘要即可 | [LiveEventCard:79](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:79) |
| 重要更新提示 | 与 DAY FlowLayout 同处 HStack，caption2 semibold + bell.badge + critical 0.18 背景 | **调整/待验证**。右侧提示会挤压 DAY 标签；大字体将提示移为独立一行，优先保证更新原因可读。提示若能定位变更，使用明确操作而不是只做静态红底文字 | [LiveEventCard:90](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:90) |
| 卡片辅助技术节点 | `.accessibilityElement(children: .ignore)` + 手工摘要，当前含标题/团体/状态/票务/日期/场馆/截止/价格/关注 | **保留并补齐**。避免把每个标签朗读一遍；现有徽章和价格遗漏已修复。仍需补无日期时“日期待公布”和刷新状态；是否加入场数/站数由关键任务决定 | [LiveEventCard:106](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:106) |
| 卡片测试标识 | 整个合并节点使用 `officialThumbnail-{id}`，不再是 `liveEventCard-{id}` | **调整**命名而非视觉。identifier 不会让图片获得独立可访问性；应按实际整卡节点命名并更新测试，避免测试以为验证了独立封面操作 | [LiveEventCard:110](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:110) |

## 4. 筛选弹层中的每种控件

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 弹层容器与完成 | `.sheet`，medium/large detents；NavigationStack + Form；完成仅 dismiss | **保留**原生组件。filters 直接 Binding，所以修改即时生效；“完成”代表关闭而非提交，应维持一致，不额外加虚假的保存按钮 | [Dashboard:149](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:149) |
| 企划 Picker | Optional 枚举 selection，nil “全部”，未指定 pickerStyle | **保留**Form 默认样式。只有三项，不需 custom radio；当前 section header 和 row label 都叫企划，可减少重复 | [Dashboard:359](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:359) |
| 团体 Picker | Optional String selection，全量 bundle 的团体去重排序 | **调整**。控件合适，但未随企划收窄，可能组合出必然零结果；按企划筛选选项，失效选择要明确清除或提示，不能静默保留看不见的值 | [Dashboard:370](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:370) |
| 活动类型 Picker | Optional EventType，各项带 tag，Live/Fan Meeting 用 verbatim | **保留/调整**。绑定类型正确；英文类型是否保留取决于全 App 术语策略，不能把产品分类和官方原文混为一谈 | [Dashboard:378](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:378) |
| 只看关注 / 待办 | 两个独立 Toggle，直接绑定 Bool | **保留**。独立开关可以组合，不应换成 mutually exclusive segmented control | [Dashboard:387](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:387) |
| 启用日期范围 | 自定义 Binding 把 optional ClosedRange 转 Bool，开启时生成今天到一年后 | **缺陷（往期语义）**。弹层没收到 scope，往期也初始化未来日期。传入 scope 或显式默认范围；关闭再打开丢失旧值是否符合预期也要定义 | [Dashboard:393](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:393) |
| 起止日期 | 两个系统 DatePicker，date-only；setter 用 min/max 截住跨界值，没有 `in:` 范围 | **调整**。系统控件选型合理；用户选择跨界日期后会被悄悄夹回边界。用 `in:` 表达可选范围，或明确让另一端跟随调整，并保证日期按日而非隐藏时间分量比较 | [Dashboard:398](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:398) |
| 重置按钮 | Button 将弹层字段归 nil/false，保留年/月/搜索 | **调整**语义。可改为“重置此处条件”，并在页面统一提供“清除全部”；无需 destructive role，因为这是可重新选择的筛选状态 | [Dashboard:413](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/DashboardView.swift:413) |

## 5. “我的”元素

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 关注列表容器 | 原生 List + ForEach + NavigationLink；来源为独立 followedSummaries | **保留**。不会继承首页筛选误隐藏关注内容。若需要按近期/往期分组，增加 Section 即可，不必改成卡片网格 | [MyLives:31](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:31) |
| 标题行 | headline Text，全标题 tint | **调整**。整行已是 NavigationLink，标题不必全为链接色；primary 正文更安静，把 tint 留给明确操作。长标题保持自然换行 | [MyLives:69](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:69) |
| 日期/截止/场馆副标题 | 拼为单个 caption secondary；有截止时不再显示场馆 | **调整**。不要用一个字符串承载不同优先级。拆为日期/场馆行和可选下一事项行；后一行标明事项名称、deadline，并给准确朗读顺序 | [MyLives:81](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:81) |
| 无关注插画与文案 | overlay `ContentUnavailableView` + star Label | **调整**文案。控件合适；“在演出列表里点击关注”与实际在详情关注不一致，写明进入详情。无数据加载时目前也显示无关注，应先判断加载/失败 | [MyLives:39](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:39) |
| 浏览演出按钮 | 仅 router 非 nil 时显示，当前 AppShell 已传入 | **保留**当前修复。无需新增 NavigationLink 到第二个首页，切换已有 Tab 即可 | [MyLives:46](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:46) |
| 刷新与失败反馈 | `.refreshable` 调用 shared store，但本页面不显示 store.errorMessage | **调整**。失败时列表保持旧资料合理，但应告知“更新失败，显示已保存资料”并可重试，避免让用户以为刷新成功 | [MyLives:63](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/MyLives/MyLivesView.swift:63) |

## 6. 共享基础元素实现

| 元素 | 当前实现 | 判断与具体建议 | 位置 |
|---|---|---|---|
| 横向选择容器 | ScrollViewReader + horizontal ScrollView + HStack spacing 8；隐藏滚动条；value 是稳定 ID | **保留**。数据量小，无需 LazyHStack；长选项通过横向滚动承载。隐藏滚动条时需要通过部分露出的下一项或选择入口使可滚动性明确 | [HorizontalSelectionStrip:24](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:24) |
| 选择胶囊 | Button label 为 subheadline Text，横向 padding 14，minHeight 44；selected 用 borderedProminent，否则 bordered | **保留**。有语义状态与标准按下反馈；最小高度属于 label 区域，不需再叠一层自制透明按钮。选中后字号不变，只改 semibold，避免大的尺寸跳变 | [SelectionChip:64](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:64) |
| 选中辅助语义 | 组 `.contain` + accessibilityLabel，子按钮 `.isSelected` | **保留**。不要把整组 `.ignore` 合成一个节点，否则月份不能逐项选择；是否需要显式“第几项”应经读屏实测 | [HorizontalSelectionStrip:42](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:42) |
| 自动滚到选中项 | onAppear 与 onChange 使用 proxy.scrollTo center；Reduce Motion 时无动画 | **保留**。在选项集合变化但 selection 不变时，没有专门重定位；只有实际复现选中项离屏才加对 options IDs 的监听 | [HorizontalSelectionStrip:44](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:44) |
| 选择触感 | 每个 chip 的 sensoryFeedback 以 isSelected Bool 为 trigger | **调整/待验证**。切换会同时改变旧项和新项；可能有两个反馈请求。将反馈集中到选择容器的 selection 变化，或只对 newValue 为 true 反馈，明确“一次选择一次反馈” | [SelectionChip:79](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:79) |
| 边缘滚动内容 | edgeToEdge 时 contentMargins horizontal 16 + scrollClipDisabled | **调整/待验证**。代码确实关闭裁切，与上方“clips outside its own frame”注释相反；月份旁边还有年份菜单，应核对滚动内容是否侵入邻接控件。必要时保留 margin、恢复裁切 | [EdgeToEdgeScrollContent:93](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/HorizontalSelectionStrip.swift:93) |
| 自定义 FlowLayout | Layout 协议测量各子项，以可用宽度分行；横纵间距默认 6；按每行最大高度累加 | **保留**用于小规模标签自动换行。宽度提案已限制到容器，优于只测无限理想宽。不能替内部 Text 解除 lineLimit；所有标签数据不应塞进一个不可分割超长 Text | [FlowLayout:15](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/FlowLayout.swift:15) |
| FlowLayout 放置与缓存 | 从 bounds.minX 开始逐项向右放，top-leading 放置；size/placement 分别重算，空 cache | **保留/待验证**。小标签数量无需复杂缓存。通用组件未来如支持 RTL，应显式验证放置顺序；目前支持语言以中英日为主，不列为当前阻塞。不要在没有性能证据时增加多层缓存 | [FlowLayout:23](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/FlowLayout.swift:23) |
| 通用状态动画 | ViewModifier 用 `.animation(reduceMotion ? nil : .snappy, value:)` | **保留**减少动态支持。调用方需只监听影响该局部布局的 value；首页当前监听 IDs，不会对每个文字刷新都触发集合动画，这个范围合理 | [MotionSupport:8](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Shared/MotionSupport.swift:8) |
| 字体基础 | 系统 headline/subheadline/body/footnote/caption 等语义字号 | **保留**，它们本身支持动态字号；不能将 caption 直接判定为“固定字号/不支持 Dynamic Type”。关键是容器是否允许换行、信息重要性是否匹配字号 | [LiveEventCard:46](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Dashboard/LiveEventCard.swift:46) |
| 状态颜色资产 | xcassets 有 light/dark 两套；positive #248A3D/#30D158，warning #C93400/#FF9F0A，critical #D70015/#FF453A，info #0040DD/#409CFF | **保留**语义角色。当前未定义 increased-contrast 变体，不能因此认定对比度不达标；应针对文字与实际合成背景测量。浅色徽章多以 primary 文字+淡底呈现，不能拿底色色值当文字色来判断 | [SemanticColors](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Shared/SemanticColors.swift:3) |
| 高重要性底色 | ImportanceHighBackground：light critical alpha .08 / dark alpha .16 | **保留/待验证**。通过不同透明度适应外观，但真正效果依赖卡片底色；不要把红底当成唯一重要性线索 | [颜色资产](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Resources/Colors.xcassets/ImportanceHighBackground.colorset/Contents.json) |
| 日期与金额格式 | EventFormatting 使用本地化 Date.FormatStyle、明确时区、Decimal currency 格式 | **保留**共享格式化；单日 `.date` 无年份适合当前日程，不适合所有往期场景。加入用途明确的含年份变体，避免全局统一加年导致所有 chip 变长 | [EventFormatting:5](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Shared/EventFormatting.swift:5) |

## 7. 建议的局部实现方式

### 截止与价格：复用内容，不复用布局 Spacer

以下是结构示意，不是已经应用的补丁：

```swift
ViewThatFits(in: .horizontal) {
    HStack(alignment: .firstTextBaseline) {
        deadlineLabel
        Spacer(minLength: 8)
        priceLabel
    }
    VStack(alignment: .leading, spacing: 4) {
        deadlineLabel
        priceLabel
    }
}
```

`deadlineLabel`、`priceLabel` 各自只负责条件文字，纵向分支没有无意义的 Spacer。辅助字号若明确必须纵排，可直接使用字号条件，而不是希望测量器替产品策略做决定。

### 封面：URL 身份必须与图片状态一致

最低限度是进入 `.task(id: url)` 时先清空旧 `image`，保留现有取消检查。若产品想加载中保留旧封面，则状态必须明确标明旧图，并在新 URL 失败时回到失败/占位；不能静默把 A 当成 B。没有必要为了这一点重写整个图片 pipeline。

### 年份：将互斥选项表示为单选控件

保留外部 Menu label，将内部多个动作 Button 改为 Picker，selection 仍写现有 filters.year。这样当前年份的勾选状态交给系统管理；“全部年份”仍使用 Optional<Int>.none。无需手写一套勾选图标和互斥状态。

## 8. 实施与验证次序

1. 修复可确认的状态表达问题：新封面失败残留旧图；日期范围默认值；无资料时空白；无效字段选项。具体详情项见两份分报告。
2. 调整局部布局：横竖分支分开 Spacer；关键 LabeledContent/商品行在大字体下纵排；让售票状态与主要动作先于长说明。
3. 保留原生控件：Tab、NavigationLink、Form、Picker、Toggle、Menu、ShareLink 都不需要全面自绘。仅对重复且已出现问题的模式抽出小组件，避免新增大型设计系统。
4. 进行有针对性的预览/设备验证：320/375/430pt 与 iPad 窄窗口；默认与最大辅助字号；中英日长文；加载成功/失败/URL 替换；空数据；VoiceOver；深色和减少动态效果。这里列的是下一步验证，不是已通过结果。

方法参考：apple-like-ui 与 ios-dev skills。关于 ViewThatFits“按受限轴的理想尺寸选择首个可容纳子视图”的行为，以 [Apple ViewThatFits 文档](https://developer.apple.com/documentation/swiftui/viewthatfits)为依据；自定义 Layout 的测量/放置职责参考 [Apple LayoutSubview 文档](https://developer.apple.com/documentation/swiftui/layoutsubview)。其他结论来自本工作区源码；涉及潜在布局/触感效果已标注待验证。
