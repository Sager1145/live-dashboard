# ADR 0001：共享契约 v2

状态：已接受。日期：2026-09-24。基线：`c889d13a597672b89f2472d5e0c91bd1a704332a`（核查时 HEAD 与基线相同）。

## 背景

树莓派服务负责唯一一份已验证的公共 EventBundle。iOS 在切换后只读这份资料，不再维护可以覆盖它的另一套 AI EventBundle。收藏和申请记录留在设备上，不进入公共目录。

字段权威仍是 `server/src/contracts.ts` 的 Zod 模型。JSON Schema 由它导出。现有 domain 实体名称保持不变。

## 决策

1. `/v1` 与 `bundleSchema`（`schemaVersion = 1`）保持现有契约。`npm run cli -- schema` 继续写出 `schema/live-dashboard.schema.json`。
2. 新增 `schemaVersion = 2` 与 `schema/v2/`。v2 bundle 在 v1 字段上增加来源检查时间、本地钟点、字段缺失原因、适用范围诊断、媒体 manifest 和旧 ID 别名。不另起一套实体名。
3. 旧客户端只接受 `schemaVersion <= 1`。`LiveEventBundle` 遇到更高版本时解码失败。v2 头字段由 `SharedContractV2Header` 读取。服务端不得把 v2 文档塞进 v1 响应。
4. 目录游标是不带前导零的十进制字符串，按长度再按字典序比较，不经过浮点数。事件 `revision` 只允许相等或增加。相等视为同一版本的重放。
5. `publishedAt` 仍是该业务版本的发布时间。`sourceCheckedAt` 是最后一次检查源站的时间，包含没有正文变化的 304。没有业务变化不因此增加 `revision`。
6. 公开 `scope` 只有两种：`performances` 加非空场次 ID，或 `unconfirmed`。event、edition、stop 的内部共通规则不能自动扩大适用范围。
7. 字段缺失使用 `notAnnounced`、`unresolved`、`unavailable`、`conflict`、`notApplicable`。模型把字段输出为 null，并不清除已验证的值；只有明确且已验证的撤回才清除。
8. `applicability` 只解释为何范围仍是 `unconfirmed`。官方写明尚未公布用 `notAnnounced` 或既有 `officiallyTBA`，不放进 applicability。
9. 未知本地时间保持 null。不补 `00:00`，也不制造 UTC 瞬间。
10. 已发布媒体 manifest 必须列出该 bundle 的每一张图。`pending` 不能出现在已发布 bundle 中。可下载策略必须带已校验的 SHA-256，内容路径是 `/v2/assets/<hash>/<variant>`，不能改写成源站跳转。
11. 模型任务只接收服务端给出的快照区块、允许的场次、链接、图片和字段。输出只能是 `proposed`。未知字段、任务外引用、源文中没有的 URL、超出允许场次的 scope 都拒绝。缓存键包含 provider、模型、配置、prompt、schema、parser、区块哈希、父级 scope 哈希、身份表版本和图片哈希。
12. APNs 静默通知只带 `serverInstanceID` 与 `catalogWatermark`。客户端用 HTTPS 同步，不凭推送推进 cursor。
13. 更新作业的 `target.kind` 只接受 catalog、source、event、eventSection、card、history。不接受任意 URL。

## 身份映射

公共迁移映射只包含 `event`、`performance`、`ticket`、`goods` 的 `legacyID -> currentID`，外加稳定的 `serverInstanceID`。正式备份恢复保留这个实例身份，换域名不换身份。

映射表不含收藏、申请、提醒或安装记录。客户端用映射改写本地私人记录的外键；服务端全量替换、410 和清库都不删除这些私人记录。410 只表示公共目录需要重新 bootstrap。

同一 `(entityKind, legacyID)` 只能指向一个 currentID，重复写入是重放，不是第二条事实。映射的 currentID 必须是该 bundle 里的实体。迁移中途崩溃后按这份映射重放即可，不依赖已经推进的目录游标。

灾难恢复如果不能保住单调游标，就更换 catalog epoch 或实例恢复标志并强制 bootstrap。旧 cursor 失效，身份映射和用户记录保留。

## 考虑过的做法

把 v2 字段直接写进 v1 schema 会让旧客户端把不认识的文档当成 v1 并丢掉新媒体和缺失原因。另做一套平行实体名会拆开现有 publisher 和 Swift domain。v2 采用同一实体、新的 schema 版本。

目录同步先用固定快照加整事件 upsert/delete/remap。字段级 patch 和 CRDT 留到以后，不在这份契约里。

## 后果

P1–P5 沿用现有 queue、publisher、source policy 和 domain，只消费这些类型。P6 之前，App 的生产路径仍是本机采集；v1 解码器拒绝 v2，避免把未完成的接收端误接到新文档。

`/v2` 路由、配对、安装会话和作业执行不属于本决定的实现范围。本决定只冻结它们的 JSON 形状。

## 未在本机完成的验证

Linux ARM64 上的四家官方 CLI 探测见 `docs/ARM64_PROVIDER_PROBE.md`。这次环境是 macOS arm64，不能代替该探测。
