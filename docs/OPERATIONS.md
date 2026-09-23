# 运行、审核与恢复

后端启动方式见 README。所有 CLI 命令在 `server/` 执行。生产采用 PostgreSQL 18.6；本地测试 PGlite 不能替代 PostgreSQL 18 并发与运维验收。

## 来源接入

1. `npm run cli -- seed` 登记研究文件中的 URL；默认禁用。URL 保留未知参数及 `p`、`_id`。
2. 阅读站点 robots、条款与实际页面，记录审核日期、允许路径、频率、媒体展示方式。示例策略：

```json
{"id":"bangdream-official","host":"bang-dream.com","enabled":true,"reviewStatus":"approved","robotsCheckedAt":"REPLACE_WITH_REVIEW_DATE","termsReviewedAt":"REPLACE_WITH_REVIEW_DATE","allowedPaths":["/events/REVIEWED_SLUG/"],"minimumIntervalSeconds":60,"requestBudget":100,"timeoutMs":20000,"maxDecompressedBytes":5242880}
```

3. `npm run cli -- source-policy https://bang-dream.com /absolute/reviewed-policy.json` 更新策略；`npm run cli -- enable-document DOCUMENT_UUID` 启用单个文档。
4. scheduler 只为已批准来源排队；worker 控制抓取、保留原始快照、创建解析任务。新发现链接仅登记待审，不自动取得抓取权限。
5. 对支持模板运行 `npm run cli -- propose SNAPSHOT_UUID`。后台先核对证据再发布，禁止直接改 `events.bundle`。

403、验证码或错误模板：暂停来源，保留最近已发布资料；检查原因和站点要求后再启用。429 遵守 Retry-After。404 不表示公演取消。截图、图片和第三方素材默认只提供官方链接，展示／缓存许可需单独确认。

## 发布、更正与回滚

`/admin` 的候选页面并排显示旧版本和新版本，原始快照转义展示，不执行其 HTML。按证据核实每个关键字段及 Day／城市范围，记录原因并核验，随后发布。基础版本落后时重新创建候选；不能强制覆盖。

手工更正使用完整 Bundle JSON 加来源快照证据，通过 `review-json` 或后台提交。回滚入口选择历史版本，生成新的审核；通过后发布新的 revision，不倒退目录游标。正式撤回或合并写 tombstone/remap，并撤销待发送提醒。原始研究清单不能当审核证据。

## 通知

环境变量：`APNS_TEAM_ID`、`APNS_KEY_ID`、`APNS_TOPIC`、`APNS_KEY_FILE`。开发 token 使用 sandbox，生产 token 使用 production。凭证不足会明确失败，不产生虚假成功。`NOTIFICATIONS_ENABLED=false` 是初始默认；准备凭证、授权设备并验证后设为 `true`。

Outbox 与公演版本在一个事务提交；通知 worker 幂等消费。截止提醒在发送前重新核对最新发布版本、场次范围、订阅和期限。APNs 与数据库无法跨服务原子提交；丢失确认时可能重试，稳定 collapse ID 降低重复展示，不能宣称严格 exactly-once 或保证送达。

## 权限与健康

Docker Compose 是本地部署配置，默认端口只绑定 loopback。生产给 API、采集、通知分配独立数据库用户，参考 `infra/database-roles.sql`；API 进程内仅 Publisher 模块写公共事实。采用受限网络出口并给 API 配置 HTTPS 反向代理；生产不要直接复用本地迁移管理员连接。

`GET /health` 检查数据库连通；`/admin/sources` 查看来源与文档状态；`/admin/operations` 查看任务、候选与通知积压；`/admin/reports` 查看用户纠错。原始快照、安装凭证和 token 不进入公共日志或公共 API。

## 备份与恢复

```sh
DATABASE_URL='postgres://...' ./scripts/backup.sh /absolute/backup-directory
# 在新的空数据库恢复，不能指向当前生产库：
RESTORE_DATABASE_URL='postgres://.../empty_restore_db' ./scripts/restore.sh /absolute/backup.dump
```

快照正文与证据保存在数据库中，随数据库备份一起恢复。恢复后待发通知暂停；核对历史投递、游标、订阅后再恢复。备份脚本成功不是恢复演练完成，必须实际恢复到独立 PostgreSQL 并检查 API 与版本历史。

## iOS 验证

```sh
xcodebuild -project ios/LiveDashboard.xcodeproj -scheme LiveDashboard -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/LiveDashboard.xcodeproj -scheme LiveDashboard -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO test
```

设备名称按 `xcrun simctl list devices available` 调整。真机、APNs、签名、TestFlight 需要用户 Apple 开发者身份和设备；填写实际 Bundle ID 与 Team 后验收。清理公共缓存不删除 SwiftData 中关注、卡片设置和手动申请记录。

## 工具链来源

锁定版本按 [Node 24.21.0 官方发布](https://nodejs.org/en/download/archive/v24.21.0) 和 [PostgreSQL 官方版本表](https://www.postgresql.org/support/versioning/) 核对；升级补丁后重跑契约、数据库和模拟器测试。

## 多来源、重放与维护

总页先 `propose`，子 Day／商品页面先 `import-snapshot`，再运行 `npm run cli -- augment-review REVIEW_UUID SNAPSHOT_UUID [PERFORMANCE_UUID]`。明确指定场次意味着审核人必须核对该子页确实属于该场；没有该证据时不传场次，保留待确认范围。票种和受付不会自动生成全排列关联；在候选编辑器中填写有原文证据的 `ticketOffers`（包括 `performanceIDs` 证据）。修改候选后会撤销其已核验标记，须重新核验。

适配器更新后 `npm run cli -- reparse SNAPSHOT_UUID` 以适配器版本集合生成幂等任务键。旧候选与旧发布版本保留，重放不会直接修改公共资料。生产版本回退必须通过正常审核发布。

调度默认：列表6小时、确认事项临近72小时1小时、进行中的已确认受付2小时、远期详情24小时、历史且无未完事项7天。来源策略可设置 `refreshIntervalSeconds`；来源请求间隔、请求数、字节预算仍优先。未确认范围不会触发临近动作加速。

后台 `/admin/sources` 可维护带审核时间的来源策略及单文档启停；每次操作需要原因。`/admin/reviews/:id` 可编辑候选、查看原始快照和版本对照。生产部署需给该后台配置实际管理员身份与 HTTPS；本地 Basic credential 只用于最小部署。

## 私有 BlobStore 与媒体

直接运行时设置 `BLOB_ROOT` 为私有目录（权限700）；Compose 使用独立 `blobs` 卷，API 只读、worker 可写。快照正文仍在数据库供审核和恢复，原始字节另按 SHA-256 放入私有存储。不要将 Blob 根目录作为静态站点公开。

媒体 `link_only` 不下载；`permitted_remote_display` 不取得缓存许可；只有 `permitted_cache` 并且来源网络策略已批准才允许缓存。媒体 magic bytes、尺寸和总字节上限通过后写入版本。同 URL 字节改变会生成新版本，发布审核批准该 `version` 与 `contentHash` 后 `/v1/media/:id/content` 才能公开返回对应内容；不会自动展示最新未审缓存。

备份必须同时保留数据库 dump 与 BlobStore 对象。对象键是内容寻址且不覆盖，先做数据库 dump，再备份全部已落盘对象即可包含该 dump 引用的内容。恢复时先将对象恢复到私有目录，再恢复数据库，保持通知关闭并核对 hash。对象存储供应商可通过 `BlobStore` 接口替换磁盘实现。

上线前完善 [隐私说明](PRIVACY.md)，并核对真实运营者、日志保留、删除入口、素材许可及数字配信外链的上架规则。

CI 的 Apple 工具链锁定 `macos-26` / Xcode 26.6，模拟器使用 iOS 26.4.1 iPhone 17 Pro；可用版本按 [GitHub 官方镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) 核验。本机另以 Xcode 27.0 验证；[Apple SDK 表](https://developer.apple.com/xcode/system-requirements) 列出了对应支持范围。CI 工作流已配置，但尚未推送触发远端执行。
