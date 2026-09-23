# 原生 SwiftUI 全页面改动计划

日期：2026-09-23。状态：计划，尚未实施。依据当前工作区与三份元素级审查；工作区仍有并行修改，实施每一阶段前重新核对相关符号，已修复项仅做回归验证。

目标：优先采用 Apple 提供的 SwiftUI 控件、容器、数据流及辅助功能 API，减少自定义外观和重复状态逻辑，让浏览演出、选择场次、查看票务、记录个人进度、读取官方/AI 资料的路径清楚可靠。

## 1. 平台基线与官方依据

项目实际部署目标为 iOS 18，支持 iPhone 和 iPad，Swift 6。保持最低版本，不以 UI 重构为由提升部署目标。iOS 26 的 `safeAreaBar` 等能力继续受 availability 检查保护；系统导航与控件在对应 SDK/OS 上采用系统外观。

| 官方依据 | 本计划如何应用 | 边界 |
|---|---|---|
| [Apple：Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) | 保留标准 bars、toolbar、sheet 和控件；移除干扰系统导航/控件外观的重复背景；新效果只由必要的系统组件承担 | 不给每张内容卡加玻璃、不自绘系统 Tab 样式 |
| [Apple：Picker](https://developer.apple.com/documentation/swiftui/picker) | 年/月、分区、资料来源、密度、语言、模型使用绑定选中值的 Picker；选择值与 tag 类型一致 | 是否用 menu/segmented/navigationLink 由选项数量、长度和可用空间决定 |
| [Apple：ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits) | 简短、无本地编辑状态的展示行按可用空间切换横竖版本 | 不把它当 Dynamic Type 断点，也不指望它让横向 ScrollView 自动换行 |
| [Apple：AnyLayout](https://developer.apple.com/documentation/swiftui/anylayout) | 需要保持子控件身份的横竖布局，使用 HStackLayout/VStackLayout 切换 | 不使用 AnyView 隐藏类型，也不为所有页面新增布局引擎 |
| [Apple：Managing user interface state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state/) | 局部 UI 用 private @State；子控件修改父状态用 Binding；沿用现有 Observable stores，需要生成 Binding 才用 Bindable | 保留现有依赖注入与业务 stores，不为每个视觉组件新增 ViewModel |
| [Apple：Boxes](https://developer.apple.com/design/human-interface-guidelines/boxes) | 独立资料组采用 GroupBox，组内用间距、对齐和 DisclosureGroup 表达次级层级 | 不把整个页面包成 GroupBox，不嵌套多层盒子 |
| [Apple：Get started with Dynamic Type](https://developer.apple.com/videos/play/wwdc2024/10074/) | 使用语义字体；辅助字号必要时改纵排；在预览与设备检查真实布局 | caption 本身支持缩放，不能只凭小字体判失败 |
| [Apple：UIViewRepresentable](https://developer.apple.com/documentation/swiftui/uiviewrepresentable) | 保留图片缩放的 UIKit 桥接，SwiftUI 负责外层生命周期、工具栏和状态 | 不手动改 representable 根视图由 SwiftUI 管理的 frame/transform；内部 image view 仍由缩放容器布局 |
| [Apple：Accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app) | 按页面与状态检查描述、触区、对比度、截断、Dynamic Type，并加入有针对性的 XCTest audit | 自动审计不能代替 VoiceOver 实际完成任务 |

上述是官方组件与方法依据。后文的资料顺序、折叠规则、设置分组和提交拆分是本项目的设计决策，不表述为 Apple 强制要求。

## 2. 明确保留与替换

### 保留

- `TabView` 四个入口，各自 `NavigationStack`，现有 `DetailRoute`、深链与场次恢复。
- `NavigationLink` 表示导航；`Button` 表示动作；`Toggle` 表示二元持久状态；`Picker` 表示互斥选择；`Link` 表示外部链接。
- `Form`/`List`/`Section`、系统 DatePicker、SecureField、ShareLink、confirmationDialog、sheet/fullScreenCover。
- 现有官方图片 pipeline、请求头、缓存、原字节分享。为了“更原生”替换成 AsyncImage 会丢失既有数据行为，因此不替换加载服务。
- `UIScrollView` 图片缩放桥接，以及已实现的 VoiceOver 放大/缩小/重置。
- 官方抓取、AI 生成、翻译、提醒、SwiftData 与持久化 schema 的业务职责。仅为真实 UI 缺陷局部增加状态信息。

### 调整

- 年/月/场次选择优先使用系统 Picker；减少自绘胶囊选择器用途。
- `DetailCard` 内部使用原生 `GroupBox`，保留外部业务接口、配置键和刷新/隐藏能力。卡内不再叠加同样背景和圆角。
- 首页封面卡仍保留轻量 SwiftUI 组合，因为它是媒体导航入口；使用语义背景、系统字体和标准导航，不增加自定义按钮动画。
- `FlowLayout` 仅保留在确实需要任意宽度标签换行的非交互内容处，继续使用 Apple `Layout` 协议；少量动作行用标准 stack/AnyLayout。
- 非阻塞状态采用 Label/ProgressView 和可执行恢复按钮；错误不全部变为 Alert。

## 3. 统一实现规则

### 控件与交互

1. 主要申请/购买/重试动作按上下文使用 `.borderedProminent`；同一渠道组有多个等价渠道时同权展示，不任意突出数组第一项。
2. 次级动作使用默认/bordered Button，低频动作进 Menu。导航与按钮尽量采用标准控件尺寸，不统一强制胶囊轮廓。
3. icon-only 按钮保留可理解的 Label/辅助名称；只在实际命中区域不足时增大外部 frame/contentShape，不通过缩小文字解决拥挤。
4. 删除摘要保留 destructive confirmationDialog；隐藏卡片为可逆操作，直接执行且保留恢复入口。
5. sheet 有具体选中模型时优先 item 驱动；筛选和历史这种单一开关展示可保留 Bool，避免机械迁移。

### 布局与文本

- 默认沿用系统 spacing、字体、background/foregroundStyle。仅对媒体比例、列表列数、内容阅读宽度和确切触区设置必要尺寸。
- 普通展示行可用 ViewThatFits 的横排/纵排两种内容；Spacer 只放在横排分支。包含 Toggle 等有状态子控件的字号切换优先 AnyLayout。
- 最大辅助字号优先一列、纵向关键字段；不锁 Dynamic Type 上限，不用 minimumScaleFactor 隐藏问题。
- 官网标题与原文使用 verbatim；App 文案进入现有 String Catalog，保持简中、繁中、英文、日文。
- 日期使用集中格式化、显式时区；往期跨年或未选定年份时显示年份。货币继续现有货币格式化。

### 状态与配置

- 保持 view/state/store 单一事实来源；不要同步两份 selection。
- 图片状态包含请求身份，加载失败不能将旧 URL 的图片伪装成新封面。
- 翻译状态保存 event + page/card scope，错误与重试对应原始请求。
- 空态依据“当前资料来源 + 当前场次 + 当前筛选 + 隐藏配置”计算；只在确实没有可展示内容时显示无资料。
- 修改卡片配置时保留配置 key、已隐藏/置顶/排序、configuredMarker 和旧值兼容，不在 UI 重构中清空用户偏好。

## 4. 全页面目标改动

### A. 应用壳与共享组件

**文件**：`ios/LiveDashboard/LiveDashboardApp.swift`；`Features/Shared/*`；`Shared/SemanticColors.swift`；`Resources/Colors.xcassets`。

- 保留四个 Tab 和分 Tab 的导航历史；来源/分区切换不能回到首页或另建一份详情栈。
- iPad 保持相同导航逻辑，首先完成窗口缩放和阅读宽度适配；本轮不新增三栏导航架构。
- 卡片内容面使用 GroupBox；菜单仍在 label/header 中，保留 header trait 和进度指示。
- 小量重复样式只抽出必要组件：结果反馈行、可回退的键值行；图片 phase 是局部状态类型，支持字段是数据映射。优先扩展现有 DetailCard/OfficialLinksView，避免再建立一套通用组件框架。
- 状态色继续使用语义资产；以实际对比度结果决定是否补增强对比变体。颜色不是状态的唯一表达。

**验收**：Tab 切换保留各自导航；深链进入正确公演/场次/分区；GroupBox 内不重复背景；标题/菜单/内容在大字号可读可操作。

### B. 演出与往期

**文件**：`Features/Dashboard/DashboardView.swift`、`LiveEventCard.swift`、必要的 `DashboardStore.swift` 展示计算；`Shared/EventFormatting.swift`。

- 紧凑宽度和辅助字号使用一列；宽窗口使用原生 LazyVGrid。列数按当前容器可用宽度计算，不按设备型号；列宽不能大于窄窗口扣除边距后的宽度。
- 保留搜索和工具栏刷新。筛选栏改为年/月两个有名称的原生 menu Picker；“全部”保留 optional selection，选中项由系统勾选。辅助字号按纵向排列。
- 筛选摘要显示已应用条件/匹配数量，并给一个“清除全部”。刷新时间使用完整本地化句式，保持动态更新时间。
- 卡片默认顺序：封面 → 标题 → 日期/场馆 → 当前售票状态 → 最近事项；企划/团体/价格为补充信息。多场次默认显示场数，不常驻所有 DAY 标签；完整场次在详情选择。
- 官方海报默认完整 fit 于稳定比例背景，避免裁掉文字；保持现有 pipeline 的下采样。加载/无图/失败有明确内部状态，失败可通过本卡刷新重试。
- 下一事项写出类型/轮次与截止，而非只有“某日截止”；与价格的横竖布局分开，不复用 Spacer。
- 整卡 NavigationLink 的完整边界可命中；合并读屏包含关键状态、日期待公布、刷新状态、价格和关注，内部标签不重复朗读。identifier 按真实节点用途命名并同步测试。
- 首次加载/失败优先于“搜索无结果”；已有缓存时保留内容，显示失败说明与重试。
- 往期日期明确年份；现场已结束但仍有效的配信和回看保持可见。

**验收**：320pt 压力预览及实际支持设备无横向溢出；长海报/长标题可辨认；A URL 成功后换 B URL 失败不残留 A；搜索遇加载失败不误报无结果；跨年往期可区分。

### C. 筛选弹层

**文件**：`DashboardView.swift` 内 `DashboardFiltersView`；`DashboardFilters.swift`。

- 保留 NavigationStack + Form + Section + 系统 Picker/Toggle/DatePicker，medium/large detents。所有修改即时生效，“完成”只关闭。
- 接收 scope。往期启用日期范围时默认截至今天的历史区间；演出使用合理未来区间。初始具体跨度延续当前产品规则，避免加入无依据的新上限。
- DatePicker 使用 `in:` 限制可选范围，或选择一端时明确调整另一端；处理 date-only 边界，避免隐藏的时间部分排除边界当天。
- 团体选项跟随企划；企划变化导致旧团体无效时同时清除，并更新条件摘要。
- 弹层“重置”明确只重置该弹层条件；全量清除使用独立“清除全部筛选”，包含年、月、搜索。

**验收**：启用往期日期不会落入未来；边界日包含；无效团体不残留；关闭弹层不回滚即时修改；重置行为与文案一致。

### D. 我的

**文件**：`Features/MyLives/MyLivesView.swift`；必要的 followedSummaries 展示计算。

- 保留 List。以 Section 分开即将到来和已结束；有待办事项的行把“事项名称 + 截止”独立显示，不新建待办数据库。
- 标题用 primary；日期/场馆用 secondary，避免整页标题都像蓝色链接。
- 加载、失败、真正无关注分别呈现；无关注使用 ContentUnavailableView，并保留已接通的“浏览演出”。说明改为进入详情后关注。
- `.refreshable` 失败显示保留缓存的说明；缓存缺失的详情给重新获取入口。

**验收**：关注列表不受首页筛选影响；未加载时不误报无关注；截止行不隐藏场馆；浏览入口切换原 Tab。

### E. 详情公共框架与选择器

**文件**：`Features/LiveDetail/LiveDetailView.swift`、`PerformanceSelector.swift`、必要的 `LiveDetailStore.swift`。

- 顺序确定为：标题 → 当前资料来源/严重公告 → 场次和分区 → 关注/参加/提醒 → 分区内容。选择区按阅读需求保留吸顶，避免堆三排同样的 segmented 控件。
- 场次改原生 menu Picker，标签显示当前日期+场次；完整场馆/副标题在其下显示。若场次很多，改用原生 List 的选择页，仍绑定同一 selectedPerformanceID。
- 四个分区在常规宽度用 segmented Picker；辅助字号用 menu Picker，保留相同选中状态和名称。
- 资料来源常规为两项 Picker，标签“官网资料 / AI 整理结果”；辅助字号 menu。清楚标明这是查看已保存内容，“重新生成”保留单独 Button。
- 保持现有“生成后切换 AI 结果”的产品行为，但必须显示切换后的来源，并向辅助技术说明；生成失败保持原来源。来源切换优先保留有效场次，失效则按现有 reconcileSelection 选择有效项并显示新的选择。
- 严重通知在普通操作之前。与官方事实有关的状态不能因切换来源而静默消失；实施时核对当前官方/AI 公告选择逻辑，必要时保留官方严重公告独立显示。
- 关注/参加保持 Toggle(.button)；提醒保持 Button。操作区用系统布局随宽度/字号调整，减少手工胶囊修饰。
- toolbar 保留常用动作；历史等次级动作可进 Menu。生成、下载、翻译用准确 ProgressView label，不把所有活动都叫“翻译中”。
- 历史 sheet 保留 List/DisclosureGroup；来源状态转本地化文案，证据提供“显示更多”，不静默截前 20 条。

**验收**：任意资料来源×场次×分区组合有效；生成失败不改变所看来源；官方严重公告始终可见；大字号可选择所有分区；导航/滚动不会隐藏当前来源含义。

### F. 概要、票务、周边、座位

**文件**：`Overview/OverviewView.swift`、`Tickets/TicketsView.swift`、`Goods/GoodsView.swift`、`Seating/SeatingView.swift`、`OfficialLinksView.swift`、`DetailCardMenu.swift`。

| 区域 | 默认常驻 | 渐进展开/控件 | 特别修复 |
|---|---|---|---|
| 概要 | 时间、会场、关键票价与入场限制 | 独立 GroupBox；LabeledContent；长出演名单/说明用 DisclosureGroup | 无场次显示一次 ContentUnavailableView；票种+价格窄宽改纵排 |
| 售票 | 当前状态、最近需处理的截止、对应官方申请/付款动作、适用范围、影响资格的限制 | 原生 Section 分受付/配信/特典；关闭轮次和长说明 DisclosureGroup；个人申请/付款仍为 Toggle | 不把当前付款截止或关键资格藏进折叠；按真实阶段选择关键字段；补完全空态/全隐藏态 |
| 配信 | 平台、销售截止、回看截止、可执行官方入口 | LabeledContent + Link；已失效项目可折叠 | 现场已结束不等于配信已失效；只有数据支持可操作时用 prominent |
| 特典 | 内容摘要、领取期限与地点 | 图片缩略图、完整说明 DisclosureGroup；原图全屏 | 长图片不隔开有效票务和配信操作；不同票种关联清楚 |
| 周边 | 批次、销售方式、开始/截止、资格、官方入口 | 商品/变体使用原生 stack/Grid；长清单、配送和图片展开 | 名称/库存/价格大字体可纵排；官方和 AI 链接来源分别标注 |
| 座位 | 本场/场馆参考类型、适用场次、图像 | GroupBox + Label + 原图 Button | 通用图、适用未确认有文字+符号；无图、失败、隐藏不同状态 |
| 链接 | 实际主操作；来源域名 | Link + Label；次级支持/来源列表可 DisclosureGroup | 商品专属链接不集中成失去对应关系的总按钮；等价渠道同级展示 |

“精简/完整”控制次级内容，关键日期、风险、资格、当前待办、恢复入口不得被精简模式省略。官方原文仍可展开或打开来源。

### G. 卡片配置与恢复

**文件**：`Features/CardSettings/CardSettingsView.swift`、`LiveDetail/DetailCardMenu.swift`、`Domain/Models/CardConfiguration.swift`，必要的现有 UserDataStore 配置方法。

- 保留系统 List、EditButton、onMove、DisclosureGroup、Toggle、Picker 和恢复确认。
- 增加每种 CardType 的实际支持字段映射，以真实 `shows(_:)` 使用为依据。例如时间会场为 time/place，票价为 price；逐类型核对，不靠猜测生成所有开关。
- UI 仅渲染支持字段。沿用旧 `Set<String>`、配置标记和 key；修改支持字段时不抹除其他历史/未知字段，旧的“空集合=全部显示”语义保持。无需一次性 schema 迁移或重置全部配置。
- 折叠行显示已隐藏/精简/置顶摘要；隐藏时仍可预先配置。
- 全局默认与本公演覆盖写明作用域；置顶高于排序的规则在 footer 解释。
- 恢复默认确认说明覆盖哪些设置。隐藏卡片保留即时撤销和永久恢复显示；VoiceOver 下撤销提示不要过早自动消失。

**验收**：每个开关改变真实对应内容；旧配置仍可读、显示零字段也可保存；全局/单公演不互相误覆盖；隐藏、恢复、置顶、重排组合正确。

### H. 图片、分享与翻译

**文件**：`OfficialMediaView.swift`、`DetailCardMenu.swift`、`Services/Translation/TranslationStore.swift`、`LiveDetailView.swift`。

- 预览用 SwiftUI Image、Button、ProgressView、ContentUnavailableView；失败与原始无图分别处理。请求取消不显示失败；任务身份包含 URL/版本，杜绝旧响应覆盖新请求。
- 全屏保留 fullScreenCover + NavigationStack + 原生 toolbar。失败增加重试与浏览器打开；关闭始终可用。
- 图像为主体：底部默认短说明与来源域名，完整 URL 收入资料 DisclosureGroup 或 Menu，并提供复制。ShareLink 和原始文件字节不变。
- UIKit 缩放保留 1x/3x 双击及捏合；程序动画遵守 Reduce Motion；无 caption 提供“官方图片/座位图”等名称；缩放比例作为 accessibility value，保持旋转后可用。
- 翻译请求保存 page/card 的明确作用域，按 event 校验状态展示；卡片失败重试该卡请求，不能悄悄改成整页翻译。
- 单卡显示译文时卡内展示简短翻译归属；页级译文展示页级归属；原文回退与部分翻译状态清楚，不以颜色区分语言。

**验收**：原图 A/B 切换与失败恢复正确；缩放/旋转/读屏/分享都能完成；所有分享仍为原字节；卡片翻译失败只重试原卡，切换公演不显示其他公演的错误。

### I. AI 摘要与设置

**文件**：`Features/Assistant/*`；必要的现有 coordinator 展示状态。

- 保留 CardPhase 状态机，补齐未登录、空、生成中、失败有旧摘要、失败无旧摘要、已完成、已过期的预览与恢复路径。
- 顺序为来源/过期提示 → 本场关键警告和下一事项 → 简短总览 → 更多重点/结构化字段 → 常规操作。警告不因精简模式消失。
- 旧摘要可以降级展示，但重试、取消按钮不随旧内容一起减透明度；过期提示紧邻重新生成。
- 生成中 symbolEffect 在 Reduce Motion 时停用。富文本沿用 AttributedString，日期与外层字体一致，保留数字对齐；链接仍有下划线，警告有文字/符号。
- 设置继续 Form。登录前聚焦主要登录入口；API Key 作为可展开的另一种连接方式。登录后展示模型、测试连接、自动整理。
- 模型继续 navigationLink Picker，保留原始 ID，推荐项另加简短用途而不伪造可用性。自定义输入用 FocusState；登录、测试、清理有对应 busy/结果反馈，返回系统设置后通知状态重新读取。
- 高级连接设置使用 NavigationLink + Form；保留凭据与 OAuth 行为，不在 UI 计划中更换认证实现。

**验收**：旧摘要可继续读且重试明显；AI/官方来源不混淆；生成失败不覆盖官方资料；模型切换与账号状态改变清除过时测试结果；所有敏感输入沿用 SecureField/钥匙串路径。

### J. 设置主页与可选历史后台

**文件**：`Features/Settings/SettingsView.swift`，同文件内拆小型私有子页或放入 Settings 目录；`server/src/api.ts` 为独立低优先级工作。

- 设置首页分为显示与卡片、语言与翻译、提醒、ChatGPT 助手、资料管理。App 语言不再放在提醒组。
- 日常设置继续 Form；资料管理进入二级 Form，包含立即更新、上次检查、历史日期抓取。保留所有功能，只减少首页长表单。
- footer 留用户决策所需短说明，完整规则进说明页。历史抓取成功/失败与普通更新使用一致 Label 语义。
- 后台不属于 SwiftUI 改造：保持服务端 HTML，单独补 label、表头、空态、窄屏单列、当前导航状态、发布/撤回层级；保留浏览器默认键盘焦点。不影响 iOS 完成条件。

## 5. 实施批次、依赖与每批交付

| 批次 | 内容 | 依赖 | 交付与验证 |
|---|---|---|---|
| 0 | 重读当前源码，核对已修复项，准备离线 fixtures 与 Preview 状态 | 无 | 单场/巡演/跨年/售罄/付款/配信/无图/错误/AI 过期样本清单；当前基线构建 |
| 1 | 图片身份、有效字段、日期筛选、翻译 retry scope、空态等正确性 | 0 | 小范围修复；对应行为测试；既有配置兼容检查 |
| 2 | GroupBox、原生选择器、横竖布局、字体与反馈组件 | 1 | 首页与详情各一个代表页面验证，再迁移相同模式；每步编译 |
| 3 | 演出、往期、筛选、我的完整交互 | 2 | 搜索/筛选/关注/刷新/跨年流程及大小字号截图 |
| 4 | 详情框架、资料来源、场次、四分区和卡片菜单 | 2，1 的配置/翻译修复 | 来源×场次×分区组合验证，所有关键截止和原文入口可达 |
| 5 | 媒体完整流程、AI 摘要、设置架构 | 4，1 的图片状态 | 分享、缩放、失败重试、登录/模型/设置反馈检查 |
| 6 | 全局可访问性、iOS 18 回退、iPad 窗口适配与本地化验收 | 3–5 | 下表验收矩阵、截图和审计记录；未解决问题明确列出 |
| 7 | 历史后台低成本修整 | 与 1–6 无依赖，最后处理 | 浏览器键盘、语义表单、窄屏验证 |

建议按这些批次分别提交，避免一笔同时重写所有视图。开始实际实施时先协调已有未提交修改；只提交本轮明确修改的文件/区块，回退按批次，不重置用户已有代码或数据。

## 6. 验证计划与完成标准

### 有意义的自动验证

- 数据/状态测试：卡片字段支持矩阵与旧标记兼容；日期边界与往期默认值；图片 A/B 任务身份；来源切换场次保留/回退；卡片翻译失败作用域。
- 使用现有 NavigationUITests 追加少量关键流程：筛选恢复、关注入口、来源/分区切换、全部隐藏恢复、媒体失败重试。避免为 padding、颜色常量、每个 Text 复制实现写测试。
- 对代表性的主页、售票、设置、图片失败页运行 `performAccessibilityAudit`；对每个独有页面/关键状态做人工 Accessibility Inspector 检查。
- 构建与测试沿用仓库命令，destination 使用实际安装的可用模拟器，不写死不存在的运行时。当前阶段只制定计划，不把这些检查描述为已通过。

### 人工和预览矩阵

| 维度 | 必查内容 |
|---|---|
| OS | iOS 18 最低兼容环境与当前可用最新稳定系统；若 iOS 18 runtime 不可用，保留明确待验项，不用较新系统替代声明通过 |
| 宽度 | 小屏/常规 iPhone；iPad 横竖屏与窄窗口；320pt 作为 Preview 压力用例，不假装它对应当前支持的某型号 |
| 文字 | 默认、最大普通字号、最大辅助字号；简中/繁中/英/日；长日文标题/票种/URL/邮箱 |
| 外观 | 浅色/深色、增强对比、减少透明度、减少动态效果 |
| 状态 | 首次加载、缓存可用、刷新失败、无结果、所有卡隐藏、无场次、图片失败、官方/AI/过期/生成中/取消 |
| 输入 | 触摸、VoiceOver；iPad 键盘与指针；表单焦点和关闭键盘路径 |
| 核心任务 | 找演出、选场次、确认截止/资格、打开正确渠道、记录申请/付款、设置提醒、看原图与分享、辨认来源、恢复隐藏 |

### 完成定义

1. 每个页面都有明确加载、无资料/无结果、失败和可恢复路径，不出现无解释空白。
2. 所有可见设置真实生效；旧配置、个人记录、关注和来源资料保留。
3. 大字体关键内容不截断，按钮命中与读屏名称经实际审计确认；不通过缩字或隐藏辅助信息“修好截图”。
4. 官方、AI、翻译来源始终可辨认；场次范围和当前有效操作正确。
5. iOS 18 回退和 iPad 窗口表现有实际记录，未测试维度明确留项。
6. 相关构建与行为测试通过；新增截图、审计结果与改动清单对应同一实现版本。

## 7. 本计划的代码范围

主改动集中在现有 Features 与 Resources。服务/数据层仅处理 UI 所必需的请求身份、作用域或配置更新，不改抓取解析器、API schema、认证协议或后端发布流程。既有 UIKit 缩放是有明确任务依据的官方互操作用法；自定义 FlowLayout 仅在标准布局无法表达真正标签换行时保留。

实施依据：[元素总报告](/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-23-ui-elements.md)、[详情报告](/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-23-ui-elements-detail.md)、[设置与后台报告](/Users/sager/Documents/GitHub/live-dashboard/docs/audits/2026-09-23-ui-elements-settings-admin.md)。已修复项不重复改动，以实施时当前源码为准。
