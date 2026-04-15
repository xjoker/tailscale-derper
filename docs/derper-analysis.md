# DERPER 镜像分析与自建方案

## 结论摘要

本次对比的两个公开来源分别代表两条路线：

- `guyuan404643/tailscale-ipderp`：更像是私有二进制再封装，优势是“开箱即用、支持 IP 模式、默认非 443 端口、带一点反扫描改动”；缺点是**不可复现、不可审计、更新节奏不透明**。
- `fredliang/derper`：基本是对官方 `cmd/derper` 的标准 Docker 封装，构建链清晰、标签覆盖多个 Tailscale 版本，适合作为对照基线。

如果目标是“安全可靠、可长期维护、在中国大陆环境下可用”，建议不要直接使用 `guyuan404643/tailscale-ipderp`，而是：

1. 基于 **官方 Tailscale 源码** 自行构建 `cmd/derper`
2. 明确区分两种 TLS 模式：
   - `IP` 模式：官方已支持，使用 **自签 IP 证书 + 指纹固定**
   - `DNS-01` 模式：使用 **外部 ACME 客户端签发证书**，`derper` 走 `manual` 证书模式
3. 在大陆环境下优先采用 **双地域、双运营商/双云厂商** 部署，并保留默认官方 DERP 作为回退，待验证稳定后再决定是否禁用默认区域

## 一、`guyuan404643/tailscale-ipderp` 是如何构建的

### 1. Docker Hub 仓库信息

Docker Hub API 返回的仓库说明显示：

- 仓库：`guyuan404643/tailscale-ipderp`
- 标签很少，当前仅见 `latest`、`1.95.0`
- 仓库说明自述：
  - “基于 1.94.1 版 tailscale 源码构建”
  - “无需域名”
  - “可指定 stun 和 derp 端口”
  - 2026-02-21 额外改动：“去掉 derp 端口默认返回的搭建成功内容，防止被互联网爬虫扫到”

这说明它不是标准上游镜像，而是**带私有补丁的再发布镜像**。

### 2. 远端镜像历史还原

对 `latest` 与 `1.95.0` 做镜像配置取证后，能还原出它的大致构建流程：

1. 运行时基础镜像是 **Alpine minirootfs**
2. 设置工作目录 `/apps`
3. 将本地准备好的 `derper` 二进制复制到镜像中
   - 历史记录显示：`COPY /etc/derp/derper .`
   - 这说明最终镜像**没有公开展示构建阶段**，只暴露了成品二进制
4. 设置时区为 `Asia/Shanghai`
5. 把 Alpine 软件源替换为 **清华镜像**
6. 安装 `openssl`，创建 `/ssl`
7. 在构建期直接生成一个默认证书
8. 运行时使用 `manual` 证书模式启动 `derper`

### 3. 默认运行参数

从镜像配置看到的默认环境变量：

```text
DERP_DOMAIN=...
DERP_ADDR=:36666
DERP_STUN_PORT=3478
DERP_CERTDIR=/ssl
DERP_CERTMODE=manual
DERP_VERIFY_CLIENTS=false
```

入口命令本质上是：

```sh
./derper \
  -hostname ${DERP_DOMAIN} \
  -a ${DERP_ADDR} \
  -certmode ${DERP_CERTMODE} \
  -certdir ${DERP_CERTDIR} \
  -stun-port ${DERP_STUN_PORT} \
  -verify-clients=${DERP_VERIFY_CLIENTS}
```

### 4. 为什么它能“无需域名”

关键点不在镜像作者自己的补丁，而在 **官方 `derper` 自身已经支持 IP 主机名**。

在官方 `v1.92.5` 的 `cmd/derper/cert.go` 中，`NewManualCertManager` 已经具备以下逻辑：

- 如果 `hostname` 是 IP 地址
- 且对应证书文件不存在
- 则自动生成一个 **自签 IP 证书**
- 同时打印出应该写入 `DERPMap` 的 `CertName=sha256-raw:<证书指纹>`

这意味着：

- “IP 模式”本身是**官方能力**
- 不需要把 `InsecureForTests` 这种测试字段拿来做生产方案
- `guyuan` 镜像大概率只是把这个能力包装成了更容易直接运行的默认配置

### 5. 它和上游相比，真正可确认的私有改动

当前能确认的私有差异主要有：

- 运行时镜像不是官方建议方式，而是 Alpine 极简包
- 默认端口改成 `36666/tcp`，不是 `443`
- 默认手动证书模式
- 构建期写死了一个默认证书
- 仓库说明明确说“改掉了默认返回内容，避免被扫描”

其中最后一项最关键：这说明 `derper` 二进制**至少存在一处源码级或二进制级改动**。但由于源码未公开，无法精确审计改了哪里。

### 6. 安全与维护风险

- **不可复现**：看不到完整 Dockerfile / CI / commit hash / 补丁
- **不可审计**：无法确认私有改动是否只改了欢迎页，还是顺带改了 TLS、鉴权、日志等逻辑
- **版本关系不透明**：仓库说明写“基于 1.94.1”，但标签还有 `1.95.0` 和更新后的 `latest`
- **默认 `verify-clients=false`**：谁知道你的 DERP 地址，都可以把流量挂过来

结论：它适合当“民间现成样本”，**不适合作为你自己的生产基线**。

## 二、`fredliang/derper` 是如何构建的

`fredliang/derper` 的 GitHub Dockerfile 和镜像历史基本一致，构建链很清楚：

```dockerfile
FROM golang:latest AS builder
WORKDIR /app
ARG DERP_VERSION=latest
RUN go install tailscale.com/cmd/derper@${DERP_VERSION}

FROM ubuntu
WORKDIR /app
RUN apt-get update && apt-get install -y ca-certificates && mkdir /app/certs
COPY --from=builder /go/bin/derper .
CMD /app/derper ...
```

特点：

- **直接从官方源码构建**
- 支持多个标签，覆盖多个 Tailscale 版本
- 运行模式接近官方默认设计
- 证书方案偏传统：域名 + `letsencrypt` / `manual`

它的问题不在“有后门”，而在于：

- 默认思路更偏域名模式
- 运行层是 Ubuntu，体积和攻击面比更精简的运行层大
- DNS-01 不是内建能力，需要外部 ACME 工具配合

## 三、DEV 文章的核心做法

`dev.to/lucifer1004/custom-tailscale-derp-server-n73` 的文章本质是在教你：

1. 用 **外部 Certbot + Cloudflare DNS 插件** 申请 DNS-01 证书
2. 把证书复制到本地目录
3. 用 `fredliang/derper` 的 `manual` 模式挂载证书启动
4. 在 Tailnet ACL 里配置自定义 `derpMap`
5. 用 `curl -Iv` 与 `tailscale netcheck` 验证

这个思路本身是成立的，尤其适合：

- `80/443` 不能直接做 HTTP-01
- 证书签发想交给外部 ACME 流程
- 需要非标准 DERP 端口

但它不是一个“安全可靠基线”，因为它更多是部署笔记，缺少：

- 镜像供应链控制
- 版本固定策略
- 客户端准入控制
- 证书续期失败告警
- 多地域回退设计

## 四、官方能力边界

## 1. IP 模式

官方源码已经支持：

- `hostname` 传入 IP
- 自动生成自签 IP 证书
- 在 `DERPMap` 中用 `CertName=sha256-raw:<fingerprint>` 做证书指纹绑定

这是一条**比 `InsecureForTests` 更安全**的 IP 方案。

推荐的 `DERPMap` 节点结构类似：

```json
{
  "Name": "1",
  "RegionID": 901,
  "HostName": "203.0.113.10",
  "IPv4": "203.0.113.10",
  "DERPPort": 443,
  "STUNPort": 3478,
  "CertName": "sha256-raw:..."
}
```

## 2. DNS-01 模式

官方 `derper` 的内建证书模式主要是：

- `letsencrypt`
- `manual`
- `gcp`

如果要用 `DNS-01`，最稳妥的路线不是给 `derper` 打补丁，而是：

1. 用 `lego` / `acme.sh` / `certbot-dns-*` 在外部申请证书
2. 把 `<hostname>.crt` / `<hostname>.key` 放进证书目录
3. `derper` 使用 `manual` 模式读取

也就是说，**DNS-01 推荐作为证书供应链，而不是 `derper` 本身的 cert mode**。

## 3. 客户端校验

官方 README 明确提醒：

- 如果启用 `--verify-clients`
- `derper` 与同机 `tailscaled` 必须来自**同一个 git revision**

所以生产上要么：

- 同机运行 `tailscaled`，并且和 `derper` 版本完全对齐
- 要么先不开 `verify-clients`，用防火墙、地域限制、流量监控降低滥用风险

## 五、面向你需求的推荐方案

你的目标是：

- 自己构建
- 安全可靠
- 同时支持 `IP` 和 `DNS-01`
- 适配中国大陆访问环境

我建议采用下面这套分层方案。

### 方案基线

- **源码来源**：固定到官方 Tailscale release tag
- **二进制来源**：自己在 CI 中 `go install tailscale.com/cmd/derper@<tag>` 或直接 `go build`
- **镜像策略**：多阶段构建，最终运行层尽量精简
- **TLS 策略**：
  - `ip` 模式：官方自签 IP 证书 + 指纹固定
  - `dns01` 模式：外部 ACME 工具签发 + `manual` 模式读取

### 为什么我不建议直接做“单容器全包”

“一个容器同时负责 DERP 服务、DNS-01 签发、续期、重载”当然能做，但不够稳：

- 运行职责混杂
- 证书续期失败更难排查
- 容器内要塞入更多依赖与凭据
- 攻击面更大

更稳的做法是：

1. **主容器**：只跑 `derper`
2. **可选证书辅助进程/sidecar**：专门做 DNS-01 签发与续期

如果你坚持单镜像支持两种模式，也建议逻辑上仍分成两个 entrypoint 分支，而不是把一切耦合到一个启动脚本里。

## 六、中国大陆环境下的部署建议

### 1. 地域建议

优先考虑：

- 香港
- 东京
- 新加坡

原因：

- 对中国大陆通常延迟更低
- 路由质量相对稳定
- 比欧美区域更适合做 DERP 中继

更稳的做法不是“一台机器”，而是**至少两个自建区域**：

- `901`：香港
- `902`：东京或新加坡

### 2. 不要放在 L7 代理或 CDN 后面

官方文档明确指出：

- 自定义 DERP 不应位于防火墙 / NAT / 负载均衡器之后
- 不兼容多数 HTTP 代理

因此：

- 不要放在 Cloudflare 橙云后面
- 不要走七层反代
- 不要用传统 HTTPS CDN
- 直接暴露公网 IP 和端口

### 3. 端口建议

优先：

- `443/tcp`：DERP
- `3478/udp`：STUN

如遇端口现实约束：

- DERP 可以改到 `3443`、`8443` 等
- STUN 也可以改端口，但兼容性和可测性通常不如 `3478`

### 4. 回退策略

初期不要立刻把官方 DERP 全关掉，建议：

- `OmitDefaultRegions=false`
- 先把自建区域加入 `derpMap`
- 用 `tailscale netcheck` 和真实中继流量验证命中率
- 稳定后再决定是否切换到 `OmitDefaultRegions=true`

### 5. 滥用控制

如果节点公网暴露，最现实的风险不是“看明文”，而是：

- 被别人白嫖中继流量
- 被探测与压测
- 被长期扫端口识别

建议分层处理：

1. 第一阶段：
   - 保留默认官方 DERP 作为回退
   - 自建 DERP 先上线并监控
2. 第二阶段：
   - 让 `derper` 与 `tailscaled` 同版本同机部署
   - 开启 `--verify-clients=true`
3. 第三阶段：
   - 做多区域与切换演练
   - 增加出口流量与连接数告警

## 七、建议你自己实现的仓库能力

下一阶段如果开始落地实现，我建议仓库至少包含：

- `docker/derper/Dockerfile`
- `docker/entrypoint.sh`
- `data/config/derper.toml`
- `README.md`
- `.env.example`

运行时建议暴露一个统一模式开关，例如：

```env
DERP_TLS_MODE=ip|dns01
DERP_HOST=...
DERP_ADDR=:443
DERP_STUN_PORT=3478
DERP_VERIFY_CLIENTS=false
DNS01_PROVIDER=cloudflare
DNS01_EMAIL=
DNS01_TOKEN=
```

其中：

- `ip` 模式：只依赖官方 `manual` + IP 自签证书能力
- `dns01` 模式：启动前先完成证书同步，再启动 `derper`

## 八、当前判断

你可以把 `guyuan404643/tailscale-ipderp` 当成“民间样本”，但不应继承它的供应链。

更合适的路线是：

- 参考 `fredliang/derper` 的**公开可复现构建方式**
- 直接利用官方 `derper` 已具备的 **IP 自签证书能力**
- 自己补上 **DNS-01 证书供应链、日志、版本锁定、准入控制、多地域设计**

这样得到的才是一个真正适合长期维护的 DERPER 容器。

## 参考来源

- Docker Hub API: `guyuan404643/tailscale-ipderp`
- Docker Hub API: `fredliang/derper`
- DEV: `Custom Tailscale DERP Server`
- Tailscale Docs: `Custom DERP servers`
- Tailscale Docs: `DERP servers`
- Tailscale 源码：`cmd/derper/cert.go`
- Tailscale 源码：`tailcfg/derpmap.go`
