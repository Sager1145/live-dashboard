# Pages 集中采集与发布

官网资料由 GitHub Actions 统一抓取，结果作为 JSON 快照发布至 GitHub Pages，iOS 只下载快照。网站首页显示「正在构建中，当前不可用」，不提供 dashboard UI。接口地址只存在于 App 内部代码，界面、设置及同步错误不显示地址。

## 自动与手动更新

工作流 `.github/workflows/pages-catalog.yml` 在 main 上执行，每小时第 17 分钟触发，也支持 `workflow_dispatch` 和采集代码变更后的自动运行。GitHub 可能延迟或漏掉繁忙时段的定时运行，这不是精确的每小时服务保证。[GitHub 定时运行说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)

独立抓取入口为 `https://sager1145.github.io/live-dashboard/refresh.html`。入口只请求 GitHub Actions 采集任务；首页没有入口导航，App 也不会展示它。手动触发需要仅限本仓库、拥有 Actions 读写权限的 fine-grained token；凭据由浏览器直接发送到 GitHub，不写入仓库、Pages、浏览器存储或 iOS。也可直接在 GitHub 的 Actions 页面选择此工作流并点击 Run workflow。[触发接口与权限](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event)

首次上线需将代码发布到 main，并在 Settings → Pages 将 Source 设置为 GitHub Actions。运行成功后，Pages 同时发布占位页、抓取入口和 JSON。[Pages 发布配置](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)

## 数据与持久保存

`catalog-data` 分支保存 `catalog.json`，作为下一次采集的输入和持久资料库。工作流使用仓库自身的 `GITHUB_TOKEN` 更新该分支，不需要额外服务器或数据库账号。App 不写公共公演资料；用户关注、申请状态、提醒和卡片设置仍在本机。

采集复用 `LiveIngestionCore/OfficialEventScraper.swift`。以日本日期向前一个自然月为刷新窗口，保留旧快照中所有资料及已归档记录。部分官网失败时合并成功结果、保留旧资料，并记录来源失败；完全没有可用资料时拒绝发布空目录。定时与手动任务串行执行，避免并发覆盖快照。持久快照先保存到分支，再发布到 Pages；部署失败时可重新运行，先前的 Pages 内容继续可用。

## iOS 内部读取接口

`GET https://sager1145.github.io/live-dashboard/api/v1/catalog.json` 返回以下快照。接口没有网页导航或下载按钮；它是公开读取接口，隐藏导航不提供访问控制。

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-10-01T04:00:00Z",
  "lastSuccessfulRefreshAt": "2026-10-01T04:00:00Z",
  "refreshIntervalSeconds": 3600,
  "sourceFailures": [],
  "events": []
}
```

上例只说明字段格式；正式采集不会发布空目录。`events` 使用现有 `LiveEventBundle` v1 完整模型，保留场次、票务、周边、图片、来源和原文。`generatedAt` 是本次快照时间，`lastSuccessfulRefreshAt` 是最近一次所有来源成功完成的时间，首次部分成功时可能为 null。抓取失败记录包含 `url`、`kind`、`message`。

App 使用 `PagesLiveRepository` 缓存有效快照；每次成功下载后至少间隔一小时才自动重新同步，手动同步可以立即下载。下载失败或响应不兼容不会覆盖缓存。前台期间检查更新、回到前台时补同步；iOS 挂起应用后不能保证每小时执行。已有本机公演缓存可在首次网络同步前用于离线显示。

## 本地验证

```sh
node --test web/test/*.test.js
swift build --package-path ios --product PagesCatalogCLI
ios/.build/debug/PagesCatalogCLI previous-catalog.json /tmp/catalog.json
```

首次运行可传入一个不存在的旧快照路径；存在但损坏的快照会使采集失败，不会当作空目录继续。iOS 的 `PagesLiveRepositoryTests` 覆盖离线持久化、旧缓存迁移、每小时同步、失败重试、并发去重、历史查询和无效响应保护。
