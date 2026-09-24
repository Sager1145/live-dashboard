# ARM64 与官方工具探测

日期：2026-09-24。基线：`c889d13a597672b89f2472d5e0c91bd1a704332a`。

这次探测在开发机上记录本机有哪些官方 CLI。它不是 Raspberry Pi OS `linux/arm64` 的安装、登录或推理验收。macOS arm64 不能代替该验收。四家工具的订阅能力、授权和额度互相独立；本机有二进制不等于该工具可以在 Pi 上跑，也不等于可以改用付费 API。

| 工具 | 官方入口 | 本机结果 | linux/arm64 |
|---|---|---|---|
| ChatGPT / Codex | `codex` 0.153.4，路径 `/opt/homebrew/bin/codex`（Node 脚本） | 只读到版本号，没有登录、没有 `codex exec` | 未探测 |
| Claude Code | `claude` 2.1.251，Mach-O arm64 | 只读到版本号，没有 headless 调用 | 未探测 |
| Gemini CLI | `gemini` | PATH 中没有 | 未探测，标为 unavailable |
| Grok Build | `grok` 1.0.41，Mach-O arm64 | 只读到版本号，没有 `-p` 调用 | 未探测 |

宿主：macOS 27.2（build 26B5091g），`uname -m` 为 arm64，Node v26.4.0。没有运行 Chromium、没有下载图片、没有调用模型。

在 Pi 上变成可用之前，缺二进制或没有官方 linux/arm64 发布包的 provider 保持 unavailable。不用网页登录代理或另一家 API 填补。
