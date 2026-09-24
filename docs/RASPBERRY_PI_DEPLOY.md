# 树莓派一行安装与更新

适用设备：运行 64 位 Raspberry Pi OS 的树莓派，具有联网能力和可使用 `sudo` 的账号。首次安装在树莓派终端执行一行：

```sh
bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/Sager1145/live-dashboard/main/scripts/pi-bootstrap.sh | bash'
```

这条命令下载引导脚本；脚本检查架构、安装缺少的 Git 等系统工具和 Docker Compose，从 GitHub 克隆到 `~/live-dashboard`，生成仅本机保存的随机数据库密码与管理员密码，拉取 `main`，构建并启动 PostgreSQL、迁移、API、调度器、采集和通知进程，最后验证 `/health`。需要安装软件时 `sudo` 可能提示输入系统密码。64 位树莓派系统遵循 Docker 的 [Debian 安装说明](https://docs.docker.com/engine/install/debian/)；本脚本使用其便捷安装入口，已有 Docker 不会重装。

以后代码推送到 `main` 后，重复上面同一行即可自动更新；在仓库目录也可使用更短的 Git 别名：

```sh
cd ~/live-dashboard && git deploy-pi
```

首次运行会在仓库的本机 Git 配置中注册 `deploy-pi` 别名。此命令先获取 `origin/main` 并要求快进合并，再重建和重启服务；数据库卷、私有 Blob 卷和 `infra/pi.env` 不会被覆盖。若工作树有本地已跟踪文件修改，会拒绝更新。`infra/pi.env` 已被 Git 忽略，权限由脚本设为仅当前用户可读写。脚本不会自动删除数据库或卷。

默认 API 只绑定树莓派的 `127.0.0.1:3000`。在自己的电脑建立 SSH 隧道：

```sh
ssh -L 3000:127.0.0.1:3000 <pi-user>@<pi-host>
```

浏览器打开 `http://127.0.0.1:3000/admin`。用户名是 `admin`，密码是树莓派 `~/live-dashboard/infra/pi.env` 中的 `ADMIN_TOKEN`。后台可在「设置」暂停/恢复抓取，在「来源健康」审核来源策略、启停单个文档、立即抓取。来源未批准或文档未启用时，“立即抓取”会被拒绝。

后台「设置」也会列出树莓派当前 IPv4，供选择服务绑定地址。保存后在树莓派运行 `git deploy-pi` 应用；端口默认为 3000，可在 `infra/pi.env` 修改 `API_PORT`。首次也能在树莓派运行 `git deploy-pi --configure` 直接选择地址。绑定局域网 IP 会使 HTTP Basic 管理页面在该网络可访问；如需远程管理，优先保持本机绑定并使用 SSH 隧道，或另行配置 HTTPS 反向代理。

检查运行状态：

```sh
cd ~/live-dashboard && sudo docker compose --env-file infra/pi.env -f infra/compose.yaml ps
```

服务端构建和数据库迁移需要在树莓派实机验收；Mac 本地的类型检查和测试不替代 ARM64 Docker 部署。
