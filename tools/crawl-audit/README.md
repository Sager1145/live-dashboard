# 官网浏览器对照

这个目录只在开发机和 CI 上运行。iPhone App 不打包 Python、Playwright 或 Crawl4AI，刷新页面时也不连接这里。

Crawl4AI 用来回答「iPhone 为什么没抓对」：保存服务器响应、浏览器 DOM、截图和区块，再和 iPhone 的 `SourceBlock` 比较。`extraction-candidates.json` 是另一个提取器的输出，不是验收答案。

## 安装

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r tools/crawl-audit/requirements.txt
crawl4ai-setup
crawl4ai-doctor
```

固定版本是 Crawl4AI `0.9.4`。

## 采集

```bash
python3 tools/crawl-audit/capture.py --self-test
python3 tools/crawl-audit/compare.py --self-test

python3 tools/crawl-audit/capture.py \
  --url https://www.example.com/event \
  --html path/to/saved.html \
  --out /tmp/live-dashboard-snapshot

python3 tools/crawl-audit/capture.py \
  --url https://www.example.com/event \
  --browser \
  --out /tmp/live-dashboard-snapshot
```

`--browser` 会启动 Crawl4AI。短文本阈值是 0，并保留 `data-*` 属性，避免票价、截止时间和未展开页签被滤掉。完整 HTML 是回放来源。

## 署名

This product includes software developed by UncleCode (https://x.com/unclecode) as part of the Crawl4AI project (https://github.com/unclecode/crawl4ai).

Crawl4AI `v0.9.4` 的 LICENSE 在 Apache 2.0 正文之外还有这段 Attribution Requirement。开发工具的说明和 `--help` 保留它。
