# derper

双模式 Tailscale `derper` 容器和裸机 Linux 便携包：

- `ip`：适合中国大陆环境，使用官方 `derper` 的 IP 自签证书能力
- `dns01`：使用 `lego` 通过 DNS-01 获取域名证书，再交给 `derper` 的 `manual` 模式读取
- 平台：`linux/amd64`、`linux/arm64`

## 裸机一键安装

低配置 Linux（Debian/Ubuntu/RHEL 系，1C512M 起）。一行命令搞定下载、解压、向导：

```bash
curl -fsSL https://raw.githubusercontent.com/xjoker/tailscale-derper/main/scripts/install.sh | sudo sh
```

脚本会自动按 CPU 架构（`amd64` / `arm64`）拉取最新 release，校验 SHA256（如有
`SHA256SUMS`），解压到临时目录后进入向导。向导依次问：

1. **IP 或域名**：输 IP 走自签证书；输域名走 Let's Encrypt + DNS-01
2. **HTTPS 端口**：默认 443，被占用可改 8443/8444 等；脚本会探测端口冲突并提示
3. **STUN 端口**：默认 3478（UDP）；同机跑多实例时改成不同端口
4. **DNS provider / 凭据 / 邮箱**（仅域名场景）
5. **是否立即启动**

装完后自身会复制为 `/usr/local/bin/derper-installer`，提供这些子命令：

```bash
sudo derper-installer             # 重跑向导（覆盖安装：回车保留旧值）
sudo derper-installer check       # 体检 + DERPMap 片段
sudo derper-installer uninstall   # 停服务、移除 binaries（保留配置和数据）
sudo systemctl status derper      # 服务状态
sudo journalctl -u derper -f      # 跟日志
```

**改端口**直接 `sudo derper-installer` 重进向导改第 2 / 3 题，会先停旧服务再用新端口起，
不需要手编 toml。**改证书凭据**也是同样路径。

> Fork 仓库的话把命令里 `xjoker/tailscale-derper` 换成你的 owner。GitHub API 未登录
> 限频 60 次/小时，遇限频可在 `curl` 命令前 `export GH_TOKEN=ghp_...` 提到 5000 次。

## 容器运行

```bash
docker run -d --name derper \
  -p 443:443 -p 3478:3478/udp \
  -e DERP_TLS_MODE=ip \
  -e DERP_HOST=203.0.113.10 \
  -v $(pwd)/derper-data:/data \
  ghcr.io/<owner>/derper:latest
```

`dns01` 模式额外需要：

```bash
-e DERP_TLS_MODE=dns01
-e DERP_HOST=derp.example.com
-e DERP_DNS_PROVIDER=cloudflare
-e DERP_ACME_EMAIL=ops@example.com
-e CLOUDFLARE_DNS_API_TOKEN=xxxx
```

## 裸机 Linux 运行

GitHub Release 会同时发布免安装依赖的便携包：

- `derper-vX.Y.Z-linux-amd64.tar.gz`
- `derper-vX.Y.Z-linux-arm64.tar.gz`

包内含 `derper`、`lego`、`install.sh`、`derper-run`、示例配置。安装走向导，
不需要预先准备环境变量；详见上文「裸机一键起步」。安装后：

- 配置文件：`/etc/derper/derper.toml`
- 凭据文件：`/etc/derper/derper.env`（0600，含 DNS-01 token）
- 数据目录：`/data`（证书、ACME 缓存）
- systemd 服务：`derper.service`，开机自启

子命令：

```bash
sudo ./install.sh             # 向导式安装/重装
sudo ./install.sh check       # 体检 + DERPMap 片段
sudo ./install.sh uninstall   # 停服务、移除 binaries（保留配置和数据）
```

不接 systemd 直接前台跑（调试用），可改用高端口绕开 root：

```bash
tar -xzf derper-vX.Y.Z-linux-amd64.tar.gz
cd derper-vX.Y.Z-linux-amd64
mkdir -p data
DERP_HOST=203.0.113.10 DERP_ADDR=:8443 DERP_DATA_DIR="$PWD/data" ./derper-run
```

## 配置

- 示例配置文件：`data/config/derper.toml`
- 环境变量优先于配置文件
- 默认关闭 HTTP 80 端口 (`DERP_HTTP_PORT=-1`)
- 默认 HTTPS 根路径返回空白页 (`DERP_HOME=blank`)
- `DERP_VERIFY_CLIENTS=true` 时，需保证本机 `tailscaled` 与 `derper` 来自同一 Tailscale revision

## 安全

容器默认以非 root 用户 `derper` (UID 10000) 运行。`derper` 二进制通过 `setcap cap_net_bind_service` 获得低端口绑定能力。

entrypoint 默认会先以 root 修正 `/data` 权限，然后降权为 `derper` 运行服务。可设置 `DERP_CHOWN_DATA=false` 跳过自动 `chown`。

如果你的容器运行时不支持 `setcap`（如部分 Kubernetes / Podman rootless 环境），可以：

- 使用非特权端口（`DERP_ADDR=:8443`）
- 或覆盖为 root 用户运行：`docker run --user=root ...`

### 访问限制

仅把 DERP 节点写入 Tailnet DERPMap 不等于访问控制。公网可达时，默认任何知道地址的 Tailscale 客户端都可能尝试连接。

官方访问限制有两种方式：

- `DERP_VERIFY_CLIENTS=true`：通过本机 `tailscaled` 验证客户端，需挂载 tailscaled socket，并确保 `derper` 与 `tailscaled` 来自同一 Tailscale revision
- `DERP_VERIFY_CLIENT_URL=https://...`：调用外部 admission controller 判断是否允许连接，建议同时保持 `DERP_VERIFY_CLIENT_URL_FAIL_OPEN=false`

使用本机 `tailscaled` 验证时示例：

```bash
docker run -d --name derper \
  -p 443:443 -p 3478:3478/udp \
  -e DERP_TLS_MODE=ip \
  -e DERP_HOST=203.0.113.10 \
  -e DERP_VERIFY_CLIENTS=true \
  -e DERP_SOCKET=/var/run/tailscale/tailscaled.sock \
  -v /var/run/tailscale/tailscaled.sock:/var/run/tailscale/tailscaled.sock \
  -v $(pwd)/derper-data:/data \
  ghcr.io/<owner>/derper:latest
```

## 证书管理

### ip 模式

`derper` 启动时自动生成 IP 自签证书并在 stdout 打印 SHA-256 指纹。容器重启后，entrypoint 会主动读取已有证书并输出指纹，用于填入 DERPMap 的 `CertName` 字段。

首次启动后可通过以下命令提取指纹：

```bash
docker logs derper 2>&1 | grep 'sha256-raw'
```

### dns01 模式

- 启动时自动通过 `lego` 申请/续期证书
- 运行期间每 12 小时（可通过 `DERP_RENEWAL_INTERVAL` 秒数调整）检查一次续期
- 续期成功后自动重启 `derper` 以加载新证书
- 如需使用 staging 环境测试，设置 `DERP_ACME_STAGING=true`

## 健康检查

镜像内置 Docker `HEALTHCHECK`，每 30 秒通过 HTTPS 检测 `derper` 端口。查看状态：

```bash
docker inspect --format='{{.State.Health.Status}}' derper
```

## GitHub Actions

工作流位于 `.github/workflows/build.yml`：

- 每天定时检查 `tailscale/tailscale` 最新 release
- 如发现新版本，则自动构建并推送到 `ghcr.io/<owner>/derper`
- 自动产出 `linux/amd64` 与 `linux/arm64` 多架构 manifest
- 自动产出 `linux/amd64` 与 `linux/arm64` 裸机便携包并上传到 GitHub Release
- 成功后打一个仓库 tag：`upstream-vX.Y.Z`
- 可通过 `workflow_dispatch` 手工指定版本或强制重建
- 所有 GitHub Actions 均通过 commit SHA 锁定，防止供应链攻击

当前默认基线：

- Tailscale `v1.96.4`
- lego `v4.33.0`
