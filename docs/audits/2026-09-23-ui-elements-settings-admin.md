# 设置与历史后台：逐元素 UI 审计

审查范围是 `SettingsView`、`CardSettingsView`、`AssistantSettingsView` 与 `server/src/api.ts` 的 `/admin*` HTML。依据 Apple-like UI/HIG：优先采用系统控件、让状态清晰可感知、将高风险操作分层、支持 Dynamic Type/键盘/辅助技术。

**优先级。** 三个 SwiftUI 设置页属于 iOS 主体，应优先处理。`/admin*` 是可选的历史运营后台，只应接受低成本的可用性修整；不应挤占面向用户 iOS 体验的迭代。

## SettingsView — [源码](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Settings/SettingsView.swift)

下表位置列中的行号均指向该源码文件。

| 元素 | 具体系统控件与状态绑定 | 评估 | 具体实现建议 | 位置 |
|---|---|---|---|---|
| 页面容器与标题 | `NavigationStack` + `Form`，标题为“设置” | 符合 iOS 设置层级，自动获得列表、焦点及 Dynamic Type 行为。 | 保持原生结构；无需为系统默认焦点另写样式。 | `SettingsView.swift:29-31, 187-190` |
| 立即检查资料 | `Button`；触发 `refreshOfficialData()`；`dashboardStore.isRefreshing` 时 disabled 且替换为 `ProgressView` | 任务与进行中状态均清楚。`isRefreshing` 也覆盖历史抓取时，文案通过 `!isFetchingHistory` 避免错误表示。 | 结果文本继续靠近动作；可在成功后用 `.sensoryFeedback`（受系统设置约束）补充一次非视觉确认，但不必加自定义动画。 | `:33-46, 61-69, 210-219` |
| 上次检查 | `LabeledContent`，绑定 `lastRefreshedAt` 的相对时间或“尚未完成” | 正确使用只读设置行，状态不靠颜色表达。 | 可把相对时间加入绝对日期的 accessibility value，便于需要精确时间的 VoiceOver 用户。 | `:48-60` |
| 更新反馈 | `Label` + 成功/警告系统图标，绑定 `refreshMessage`/`refreshSucceeded` | 图标、文字与颜色共同表达结果，符合可感知状态原则。 | 失败时将可恢复动作（例如“重试”）留在同一 section；已有主按钮，暂不必新增。 | `:61-69` |
| 历史日期范围 | 两个带范围约束的 `DatePicker`；`historyStart` 改动会夹紧 `historyEnd` | 原生日期控件和绑定约束正确，避免非法区间。 | 在页脚加入“最多建议的区间”仅当抓取端有实际限制；否则当前说明足够。 | `:76-86` |
| 抓取历史 | `Button` + `ProgressView`；`isRefreshing || historyEnd < historyStart` 禁用；文本结果绑定 `historyMessage` | 状态、禁用逻辑与本地结果反馈齐全。 | 对失败结果增加 warning `Label`，与资料更新区保持图标语义一致；保留系统 disabled 外观。 | `:87-104, 221-229` |
| 本地时间开关 | `Toggle`，自定义 `Binding` 写入 `userDataStore.showsDeviceLocalTime` | 一项独立偏好使用 Toggle 正确，读写路径明确。 | 无需调整。 | `:111-113` |
| 卡片设置入口 | `NavigationLink` 到 `CardSettingsView` | 深层、可逆设置采用导航而非 sheet 正确。 | 可在 trailing value 显示已隐藏卡片数量，只有该指标能帮助决策时再加。 | `:114-119` |
| 翻译目标 | `.navigationLink` 风格 `Picker`，`@AppStorage` 绑定语言 raw value | 对多选项使用导航选择器，能适应本地化和大字号。 | 无需改为 segmented；选项会随语言数增长。 | `:124-132` |
| 通知与 App 语言 | `LabeledContent` + 条件性“去设置开启”按钮 + `openURL` 系统设置 | 仅在 denied 时暴露修复动作，符合渐进披露。 | “App 语言”总是出现但与通知并列，建议拆到“语言” section；动作名称改为“在系统设置中更改 App 语言”，降低歧义。 | `:139-166` |
| 助手入口与披露 | `NavigationLink` 内 `LabeledContent`；状态来自 `assistant.account` | 账号状态在入口可扫读，隐私/传输说明就在进入前。 | footer 偏长；可将“数据会发送至 OpenAI”保留，其他本地数据说明移至子页，减少设置主页认知负担。 | `:169-185, 193-198` |

## CardSettingsView — [源码](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/CardSettings/CardSettingsView.swift)

下表位置列中的行号均指向该源码文件。

| 元素 | 具体系统控件与状态绑定 | 评估 | 具体实现建议 | 位置 |
|---|---|---|---|---|
| 页面、分组与编辑 | `List`/`Section`，`EditButton` 控制列表重排模式 | 采用系统编辑模式，手势和可访问性行为由平台提供。 | 保持；可在首次进入时将“编辑”用途写入 section footer，而不是自定义拖拽提示。 | `CardSettingsView.swift:29-70` |
| 总览排序 | `ForEach` + `.onMove`；绑定 `overviewOrder`，写入 `reorderGlobalConfigurations` | 排序更新持久化且置顶规则在加载时恢复。 | 当前“置顶”会改变显示次序，用户可能误以为是手动排序丢失；在 footer 明确“置顶优先于排序”，或在编辑状态显示 pinned 标识。 | `:31-43, 92-102` |
| 卡片 DisclosureGroup | `DisclosureGroup`；每类卡片的持久配置由 `globalConfiguration` 读出 | 大量次级设置折叠，层级合理。 | 折叠行没有摘要；建议在 label trailing 处显示“已隐藏”或“紧凑”，让人不展开也能判断非默认状态。 | `:105-136` |
| 显示/置顶 | `Toggle`；`visibilityBinding` 反转 `isHidden`，`isPinned` 走通用 Binding | 用 Toggle 表示即时二元偏好正确；只给可重排项提供置顶，防止死 UI。隐藏状态下仍能预先配置其余选项也合理。 | 在披露标题加入“已隐藏”等状态摘要；保持子配置可编辑，不要一律 `.disabled`。 | `:108-112, 159-169` |
| 密度 | `Picker` 的 `.segmented` 变体，绑定 `CardDensity` | 两项互斥且名称短，segmented 合适。`LabeledContent` 外层标签与 Picker 内 label 共同提供辅助语义；`labelsHidden()` 只隐藏视觉标签。 | 保留 Picker label；以 VoiceOver 实测是否重复朗读为准，若重复再整理外层/内层命名，不应直接删除语义 label。 | `:113-124` |
| 字段显示 | `ForEach(CardField.allCases)` 为每个已列入 `fieldConfigurableTypes` 的卡片类型生成全部字段 `Toggle`；首次修改填充字段集合和配置标记 | **缺陷：** 可配置性只按 card type 判断，未按“该卡片实际支持的字段”过滤。例如时间与会场卡实际只读取时间/地点字段，却仍会出现所有 `CardField` 开关，造成无效设置。 | 定义 `supportedFields(for: CardType) -> [CardField]`（或让卡片协议暴露该集合），`ForEach` 仅渲染并持久化实际调用 `shows(_:)` 的字段；为零项类型不显示字段区。 | `:18-23, 125-156` |
| 恢复默认动作 | `.destructive` `Button` 仅设置 `restoreTarget` | 先确认再写入，动作的 destructive role 正确。 | 由于这是可恢复的“偏好复位”而非数据删除，可不用 destructive 红色；使用普通按钮并明确“恢复本卡片默认设置”。若保留 destructive，应说明覆盖的具体内容。 | `:128-132` |
| 恢复确认 dialog | `confirmationDialog`，`restoreTarget != nil` 绑定；确认后恢复并重载排序，含 cancel | 符合确认变体的用途，标题、确认和取消齐全。 | 文案补充“将恢复显示、密度、字段及（如适用）置顶设置”，使确认对象可预测。 | `:72-89` |
| Sheet / alert 变体 | 本页没有 `.sheet` 或 `.alert`；唯一模态是上述 `confirmationDialog` | 没有为可在原地完成的设置滥用模态。 | 无需添加 sheet。 | `:72-89` |

## AssistantSettingsView — [源码](/Users/sager/Documents/GitHub/live-dashboard/ios/Sources/LiveDashboardKit/Features/Assistant/AssistantSettingsView.swift)

下表位置列中的行号均指向该源码文件。

| 元素 | 具体系统控件与状态绑定 | 评估 | 具体实现建议 | 位置 |
|---|---|---|---|---|
| 页面与 section 结构 | `Form`，六个语义 section，监听账号/模型变化清理临时结果 | 原生设置信息架构清楚，状态变化不会遗留过时结果。 | “测试连接” section 缺 header；加“连接”标题可改善扫描。 | `AssistantSettingsView.swift:39-57, 249-267` |
| 账号状态 | `LabeledContent`，基于 `assistant.account` enum 展示未登录、掩码 API key 或 ChatGPT 账号 | 仅显示必要账号信息，符合凭据留在 Keychain 的边界。 | 长 email/accountID 在大字号下应允许换行；确认 `Text` 不是单行截断。 | `:136-157` |
| ChatGPT 登录 | `Button` + `Task`；`isSigningIn`/OAuth 等待中 disabled；等待状态为 `LabeledContent + ProgressView` | 等待、禁用和取消错误处理明确。 | 登录按钮执行时也可显示 inline ProgressView，减少“为何禁用”的猜测；无需自制 sheet/dialog。 | `:67-80, 379-390` |
| API Key 输入与登录 | `SecureField`，password content type、关闭自动纠正、隐私标记、提交即登录；按钮为空/登录中禁用 | 安全输入及状态绑定良好。 | `submitLabel(.go)` 在设置语境较模糊，改为 `.done` 或保留按钮为主；登录失败应保持输入框焦点可重试。 | `:82-105, 392-403` |
| 登录错误 | warning `Label`，文字+图标+critical 色 | 不依赖颜色，位置接近关联输入。 | 错误可能很长；设置 `fixedSize(horizontal:false, vertical:true)`，并给可读的本地化恢复说明。 | `:98-106` |
| 退出登录与确认 | destructive `Button` 打开 `confirmationDialog`，确认执行异步 sign-out | 高影响操作有确认，文案说明既有摘要保留。 | 在确认中把“退出”放为 destructive 已正确；不需额外 alert。 | `:108-132` |
| 模型选择 picker | `.navigationLink` `Picker`，Binding 在推荐模型与“自定义”之间切换 | 候选模型数可能变动，导航 picker 能扩展。 | 推荐模型即时保存但 footer 才说明；在选择器页加当前模型标记与简短副标题。 | `:162-170, 232-245` |
| 自定义模型输入 | 条件 `TextField` + 应用按钮；空值或等于当前模型禁用 | 显式提交与键盘提交双路径清楚。 | 选择“自定义…”后应自动聚焦输入框（`@FocusState`）；将“切换到此模型”改为“使用此模型”更简洁。 | `:172-189, 372-377` |
| 载入模型列表 | `Button` 绑定 `isLoadingModels`、账号状态；错误文本绑定 `modelListError` | 异步禁用逻辑完整。 | 加 label 图标或“重新载入”状态，便于区别初次加载和失败重试；错误也用 `Label` 与登录错误保持一致。 | `:191-205, 419-428` |
| 测试连接与结果 | `Button` + inline progress；结果 enum 映射成功/失败 Label；成功和失败发送 Accessibility announcement | 是本范围最佳的异步反馈模式；颜色外有图标，VoiceOver 有即时播报。 | 结果行加“连接成功：”或“连接失败：”文字，避免成功时仅朗读模型名；不要因为已有系统焦点而补无意义焦点样式。 | `:249-289, 405-416` |
| 自动摘要开关 | `Toggle` 直接绑定 `assistant.autoSummarizeAfterRefresh`，未登录 disabled，footer 随账号改变 | 依赖条件、后果与用量披露清楚。 | 登录后仍可加入“仅在内容变化时”作为 toggle 下的 summary，现有 footer 已覆盖。 | `:291-303` |
| 高级 OAuth 导航 | `NavigationLink` 到嵌套 `Form`；两个 `@AppStorage` 文本框在登录后 disabled | 高级设置以渐进披露呈现，合适。 | “高级”过于笼统，改为“OAuth 客户端设置”；Client ID label 本地化；在 disabled 时显示“请先退出登录”的简短行，而非仅埋在 footer。 | `:305-336` |
| 清除摘要与确认 | destructive `Button`，空集合 disabled；显示条数和事后反馈；确认 dialog 含不可撤销说明 | 数据删除的确认、计数和反馈完整。 | 清除过程若会耗时，加 `isClearing` 并禁用重复提交；成功反馈可 accessibility announce，和测试连接一致。 | `:339-369` |
| Sheet / alert 变体 | 无 `.sheet` 或 `.alert`；有两种 confirmationDialog（退出、清除），高级页用 navigation push | 选择正确：设置编辑不需要 sheet，破坏性操作用 confirmation dialog。 | 不需增加其他模态。 | `:119-132, 353-369` |

## `/admin*` 历史后台 HTML — [源码](/Users/sager/Documents/GitHub/live-dashboard/server/src/api.ts)

此处是服务端字符串 HTML，当前只使用浏览器原生元素；无 JS 状态机。表单 POST 后由 redirect 或响应更新，CSRF hidden input 与必填原因字段由共享 `form()` 注入。

下表位置列中的行号均指向该源码文件。

| 元素/页面 | 具体 HTML 实现与状态 | 评估 | 具体实现建议 | 位置 |
|---|---|---|---|---|
| 共享壳、导航、CSS | `<nav>` + 链接，单行内联 CSS；`body/table/article/pre/input/textarea/button` | 语义基础存在，移动 viewport 有设置；但无当前页、暗色、响应式列与状态样式。 | 低优先级抽为语义 CSS token；加 `aria-current="page"`，`nav` 小屏换行，给表格容器横滚动。不要为“类 iOS”重做后台。 | `server/src/api.ts:31-32` |
| 通用表单 | `<form method=post>`、CSRF hidden、`reason` required input、button | 每个变更都有原因和 CSRF，安全流程可见。 | 为 reason 加显式 `<label>`（placeholder 不是标签）；给 textarea/input 加关联 help/error 区；保留浏览器默认可见焦点，并以键盘实测验证即可，无需为了自定义样式而覆盖它。 | `:126-135` |
| 审核队列 | 说明段、`table`、链接、JSON textarea、number input | 主数据采用表格合理；空队列会显示空表，提交大 JSON 的错误缺乏就地呈现。 | 加 `<caption>`/`thead`/空状态；把提交区放 `<details>`，textarea 加 `<label>` 与格式提示。 | `:483-495` |
| 版本与证据 | 状态段、双列 article+`pre`、快照/媒体链接、四个 POST forms | 审核信息完整，但 raw JSON 比较难扫读；发布、拒绝、编辑同一强度。 | 窄屏 `.columns` 单列；把摘要差异置于 JSON 前；发布作为唯一主操作，拒绝使用破坏性样式，编辑/核验为次级。 | `:512-536` |
| 原始媒体 | 直接返回媒体或下载 PDF，不是 HTML UI | 正确隔离，CSP sandbox。 | 无 UI 改动建议。 | `:539-554` |
| 原始快照 | 两个无标题 `<pre>`（metadata/body） | 转义文本安全，但阅读对象不清晰。 | 加 `h2`、来源与时间摘要、可滚动代码区域和返回审核链接。 | `:556-570` |
| 已发布公演 | 每事件 `article`、版本文字、revision number input、回滚/撤回表单 | 回滚与撤回均是写操作，却无明显风险分层。 | 将撤回置于 danger 区，先呈现影响与替代 ID；紧凑表格展示名称、版本、状态、操作。 | `:664-682` |
| 来源健康/策略 | 来源 article（健康、policy JSON、暂停/保存）；文档 `<table>` 但无 headers | 数据和操作混杂；文档表缺 `<thead>`，状态文本有但不易扫读。 | 分离来源摘要与策略编辑（`details`）；加 table headers、独立操作列；健康用文字+形状/图标，绝不只用颜色。 | `:722-736` |
| 运营统计 | 三个 JSON `<pre>` | 是调试输出而非运营界面，故障和积压不易识别。 | 低成本替换为三张语义表（类型/状态/数量）；零条目有明确空状态。 | `:823-844` |
| 用户纠错 | 每项一个 article，只有 event id 和正文 | 无时间、状态或进入审核的后续动作。 | 展示提交时间、关联公演、处理状态，增加“创建审核候选”入口；空状态解释纠错如何出现。 | `:846-862` |

## 实施排序

1. **iOS P1：** Card 设置按 `CardType` 过滤实际支持的字段，移除无效开关；这是直接影响设置是否生效的正确性问题。
2. **iOS P2：** Card 折叠行展示隐藏/紧凑等非默认状态；Assistant 的异步失败信息和长文本在大字号下的可读性；Settings 拆分语言与提醒。
3. **后台 P3：** 仅补表单 label、表格 header/空状态、危险操作样式和小屏单列；保留默认浏览器焦点并做键盘验证，不开展视觉重构。
