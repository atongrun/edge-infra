# edge-infra Cloudflare XHTTP 备用入口与独立内核升级方案

日期：2026-11-06。状态：代码与部署方案；不是生产部署完成记录。

## 1. 结论与范围

上一轮“Cloudflare Tunnel + 官方 cloudflared + 本地 VLESS-WS”的试点已经
放弃，不再作为受支持的备用路径。该试点在大陆手机蜂窝网络出现过可连接但
几乎收不到数据（约 32 KB / 4 分钟）的问题；UDP/QUIC-in-tunnel 黑洞、
CF 边缘 RTT 和 TLS-in-TLS 中途冻结都可能是原因。继续调 WS 参数不会改变
这些故障域。

新的首选且唯一的 Cloudflare 备用路径是：

```text
Mihomo
  → VLESS + XHTTP (packet-up) + TLS
  → 新的专用 hostname，Cloudflare 橙云，客户端端口 443
  → Cloudflare 边缘（隐藏源站 IP）
  → 源站 nginx:443（只允许 Cloudflare 公布的回源网段）
  → nginx 把 XHTTP path 转发到 127.0.0.1:<CF_XRAY_PORT>
  → 独立 Xray-core sidecar（只监听回环）
  → 目标网站
```

本变更只实现这一条 Cloudflare 路径。不同时维护 Tunnel+WS 和 XHTTP 两套
一等后端，也不把 Cloudflare 节点做成 `url-test` 组。主链仍是
`type: fallback`，顺序为：

```text
Reality → Trojan → HY2 → HY2-Hop → DediOne-Cloudflare（仅在 CF 已发布时）
```

Cloudflare 节点默认：

- `udp: false`（失败试点中的 UDP/QUIC 不可再作为默认能力）；
- `network: xhttp`，`xhttp-opts.mode: packet-up`；
- `alpn: [h2]`，不使用 h3-only；
- 不使用 mux / smux / mux.cool；
- `tls: true`，保留证书校验，不写 `skip-cert-verify`；
- `server` 可以是首选 Cloudflare anycast IP，但 `servername`、XHTTP host 和
  `Host` 头必须始终是专用 hostname；
- 不把现有 edge / subscription / Reality / Trojan / HY2 域名改成橙云。

## 2. 文件与职责

| 路径 | 作用 |
| --- | --- |
| `env/cloudflare.env.example` | 公开占位输入；复制到 `/root/edge-infra-cloudflare.env` 后编辑 |
| `env/resilience-versions.env.example` | Xray、Mihomo 校验用版本/SHA256；sing-box 升级 pin 独立保留 |
| `templates/xray/cloudflare-xhttp.json` | 127.0.0.1 VLESS + XHTTP + `packet-up` 入站 |
| `templates/nginx/cloudflare-xhttp.conf` | 独立 nginx 站点，XHTTP path 反代到回环 Xray |
| `templates/systemd/edge-infra-xray-cf.service` | DynamicUser + LoadCredential 的 Xray sidecar |
| `scripts/cloudflare-overlay.sh` | preflight / install / status / verify / rollback |
| `scripts/cloudflare-subscription.py` | 生成 Mihomo XHTTP 候选节点（不改源文件） |
| `scripts/publish-cloudflare-subscription.sh` | Mihomo 校验、原子替换、60 分钟自动回滚 |
| `scripts/upgrade-sing-box.sh` | 独立的既有 sing-box 升级事务，与 CF overlay 解耦 |

overlay 只拥有：

```text
/etc/edge-infra-cloudflare
/usr/local/lib/edge-infra-cloudflare
/var/lib/edge-infra-cloudflare
/etc/systemd/system/edge-infra-xray-cf.service
/etc/nginx/sites-available/edge-infra-cloudflare.conf
/etc/nginx/sites-enabled/edge-infra-cloudflare.conf
```

它不编辑基础 nginx 站点、现有直连 hostname、DNS、Cloudflare 设置、UFW 或
云端防火墙。UUID、XHTTP path 和订阅 token 不写入 Git；安装器不会打印
UUID 或 path。

## 3. 上线前的人工前置条件

以下操作必须由有权限的人在生产环境执行；本仓库的本地实现不会自动做
DNS、Cloudflare、远端防火墙或生产订阅变更。

1. 选择一个新的专用 hostname，例如 `backup.example.com`。不得复用现有
   edge、subscription、Reality、Trojan、HY2 名称。
2. 为该 hostname 准备覆盖它的源站证书（独立 Let's Encrypt lineage 或
   等价证书），例如 `/etc/letsencrypt/live/<CF_CERT_NAME>/fullchain.pem`
   和 `privkey.pem`。证书必须仍在有效期内。
3. 在 Cloudflare 中只把新 hostname 设为 **Proxied / 橙云**，A 记录指向
   源站。SSL/TLS 模式使用 **Full (strict)**，源站证书必须与新 hostname
   匹配。不要橙云现有直连 hostname。
4. 在云端安全组和/或主机防火墙上，只允许 Cloudflare 公布的回源 IP 访问
   源站 TCP 443。以 Cloudflare 官方列表为准：
   <https://www.cloudflare.com/ips-v4> 和 <https://www.cloudflare.com/ips-v6>。
   不要把 `0.0.0.0/0` 或 `::/0` 留在 443 上；同时保留 SSH 管理规则。
5. 注意：如果现有订阅域名仍需客户端直连源站 443，全局只允许 Cloudflare
   回源网段会让该直连订阅不可用。上线前必须明确选择：
   - 保持现有直连订阅可用，并接受源站 443 仍可被这些客户端直连；或
   - 在明确批准后把订阅交付也迁移到受保护路径；或
   - 使用独立的源站 IP/端口承载 CF 回源。

   本仓库不会替用户决定或修改这条生产边界，也不会自动橙云现有域名。
6. 确认基础栈和 Reality overlay 已安装并可用；订阅文件由 Reality state
   记录。不要在生产机上直接运行本仓库测试来修改真实服务。

## 4. 服务器部署步骤

### 4.1 准备公开配置

```sh
sudo install -m 0600 env/cloudflare.env.example /root/edge-infra-cloudflare.env
sudoedit /root/edge-infra-cloudflare.env
```

至少填写：

```text
CF_HOSTNAME=backup.example.com
CF_CERT_NAME=backup.example.com
CF_XRAY_PORT=18080
CF_XHTTP_PATH=<随机 path，以 / 开头>
CF_PREFERRED_IP=<可选，留空则客户端 server 使用 hostname>
```

路径和 UUID 属于敏感运行信息。UUID 由安装器在源站生成并保存在
`/var/lib/edge-infra-cloudflare`，不要手工复制到 Git、工单或聊天。

### 4.2 preflight、安装、验证

```sh
sudo scripts/cloudflare-overlay.sh preflight --config /root/edge-infra-cloudflare.env
sudo scripts/cloudflare-overlay.sh install   --config /root/edge-infra-cloudflare.env --yes
sudo scripts/cloudflare-overlay.sh status
sudo scripts/cloudflare-overlay.sh verify
```

preflight/install 会拒绝：

- 与非专用 hostname 相同，或已经出现在其他 nginx `server_name` 的 hostname；
- 已存在但没有 overlay state 的自有路径、unit 或 nginx 站点；
- 不覆盖 `CF_HOSTNAME` 的证书；
- 已被占用的回环端口；
- 未知/重复配置键、非法端口、非法 path 或非法首选 IP。

安装是幂等的：如果 state 已存在且配置一致，重复 install 只确认服务和
nginx 状态，不会创建第二套 unit、站点或节点。配置不一致时要求先 rollback。

### 4.3 发布订阅（带自动回滚）

确认单节点外部 HTTPS 已可用后：

```sh
sudo scripts/publish-cloudflare-subscription.sh publish --yes
```

若订阅里已经有 `DediOne-AnyTLS` 或 `DediOne-TUIC`，该命令会拒绝，而不是把
Cloudflare 节点插进这条链。默认订阅不包含 Cloudflare 或 Tunnel 节点。

该命令会：

1. 从 Reality state 读取当前订阅与哈希，拒绝 drift；
2. 用独立 Python 生成器写出候选文件，不改原订阅；
3. 按 `env/resilience-versions.env.example` 固定版本下载 Mihomo 并校验
   SHA256，执行 `mihomo -t`；
4. 用 Reality 的 `check_main_chain` 验证 CF 节点只作为最后一个 fallback；
5. 备份订阅、Reality state、Reality CLI；
6. 以同目录临时文件 + `mv` 原子替换，并设置 60 分钟自动回滚 timer。

在 60 分钟内完成手机/F50 的外部验收，然后接受：

```sh
sudo scripts/publish-cloudflare-subscription.sh accept --yes
```

若验收失败，立即手动回滚，或等待 timer：

```sh
sudo scripts/publish-cloudflare-subscription.sh rollback --yes
```

自动回滚只恢复这轮发布涉及的订阅、Reality state 和 Reality CLI；私有备份
保留在 `/var/backups/edge-infra-cloudflare`。不要在 timer 仍激活时直接改
订阅文件。

### 4.4 移除 CF 路径

先从订阅侧撤回，再移除服务：

```sh
sudo scripts/publish-cloudflare-subscription.sh rollback --yes   # 或 accept 后手动移除节点
sudo scripts/cloudflare-overlay.sh rollback --yes
```

overlay rollback 会拒绝在订阅仍含 `DediOne-Cloudflare` 时执行，也会拒绝在
订阅发布事务未结束时执行。它停止并删除 Xray/nginx 自有文件，保留私有
state 备份。基础 rollback、Reality rollback 和 Reality simplify 在 CF state
存在时都会拒绝，避免留下悬空引用。

## 5. 客户端与验收要点

Mihomo 节点名称固定为 `DediOne-Cloudflare`，必须包含：

```yaml
udp: false
network: xhttp
tls: true
servername: <CF_HOSTNAME>
alpn: [h2]
xhttp-opts:
  mode: packet-up
  host: <CF_HOSTNAME>
```

`server` 可以是首选 CF anycast IP；当 `server` 是 IP 时，`servername`、
XHTTP host 和 Host 头仍必须是 hostname。不得添加 mux/smux，不得把
`skip-cert-verify` 设为 true，不得使用 `network: ws` 或 gRPC 作为默认。

验收矩阵：

| 场景 | 证据 |
| --- | --- |
| 单 CF 节点 | 手机、F50 实际 HTTPS 成功，证书正常，DNS/连接显示经过 Cloudflare |
| 主链正常 | Reality → Trojan → HY2 → HY2-Hop 不受影响 |
| CF 故障 | 停止/隔离 CF 服务后主链仍可用，订阅不引用失效节点 |
| fallback 切换 | 隔离直连 TCP/UDP 后，新连接最终落到最后的 CF 节点 |
| UDP | 默认明确为不支持；若做 UDP 测试，必须使用真实 UDP payload，不能只看 204 |
| 长连接 | 至少 30 分钟持续请求与空闲后重连；记录中途冻结/重连行为 |
| 回滚 | 订阅恢复原哈希，Reality verify 通过，Xray/nginx 自有资源已移除 |

Clash/Mihomo 在 rule 模式下不能让用户手动选择 fallback 成员，这是预期行为。
CF 只作为 `主链路` 最后一个 fallback，不使用 `url-test` 选它。

## 6. sing-box 升级保持独立，并认既有 unit 名

`scripts/upgrade-sing-box.sh` 只针对已存在的 legacy 布局。
`/usr/local/bin/sing-box` 必须是普通可执行文件；fresh installer 的符号链接会被
拒绝。它读取 `env/resilience-versions.env.example` 的 `UPGRADE_SING_BOX_*`，
不读取 `versions.env` 的 `SING_BOX_*`。2026-11-25 核对官方稳定版后，两套 pin
都是 v1.14.4（排除 v1.15 prerelease），校验的是同名 asset
`sing-box-1.14.4-linux-amd64.tar.gz` 与 `sing-box-1.14.4-linux-arm64.tar.gz`，
不是 glibc/musl 变体。不要在部署 CF overlay 的同一次操作里顺手升级主链内核。

preflight 只读：它确认这些共享同一二进制的 unit 处于 active，并且只对配置做
`check`，不改写凭据。`upgrade` 才会重启它们：

- `sing-box.service` → `/etc/sing-box/config.json`
- `sing-box-trojan.service` → `/etc/sing-box/trojan.json`
- `sing-box-reality.service` → `/etc/sing-box/reality.json`
- `sing-box-extra.service` → `/etc/sing-box/extra.json`（unit 已安装时必须
  active。AnyTLS/TUIC 留在 extra.json；升级不会停掉这条 overlay，也不会跳过它）

下列 unit 若已安装则必须 active。升级和回滚都不 restart/stop 它们：

- `hy2-port-hopping.service`（表 `inet edge_hy2_port_hopping`）或
  `edge-infra-port-hopping.service`（表 `inet edge_infra_hy2_hopping`）。
  两者同时安装则拒绝。规则是 nft redirect 到 443。跳转端口没有 ss 监听是正常的。
- `edge-infra-xray-cf.service` 使用独立 Xray 二进制，不随 sing-box 升级重启。

```sh
sudo scripts/upgrade-sing-box.sh preflight
sudo scripts/upgrade-sing-box.sh upgrade --yes
# 外部验收：主链、AnyTLS、TUIC、hopping 转发、Xray 回环仍在
sudo scripts/upgrade-sing-box.sh commit --yes
# 或在 15 分钟自动回滚前
sudo scripts/upgrade-sing-box.sh rollback --yes
```

回滚只恢复 `/usr/local/bin/sing-box`，并重启本次事务记录的 sing-box unit。
它不改 extra 凭据、不 flush nftables、不重载 nginx、不替换 Xray。自动回滚已经
执行时，commit 会拒绝。旧版本脚本留下的进行中事务没有 unit 列表；用 rollback
或等待它自己的 timer，不要用新脚本 commit。

Xray pin 是 v26.11.9（commit `676eaf66f8f05d4d558ee7a74b4736623d3feeb9`），
asset 为 `Xray-linux-64.zip` 与 `Xray-linux-arm64-v8a.zip`。已有 overlay state
时再次 install 不会替换二进制或 UUID。改 pin 本身不会重装 sidecar。

不要把该脚本指向真实生产环境做演练；本仓库测试只覆盖失败门禁、unit 分类和状态机。

## 7. 本地验证与已知限制

```sh
./scripts/verify.sh
./tests/run.sh
```

测试覆盖：配置解析、直连 hostname 守卫、Xray/nginx 模板静态约束、安装失败
清理、订阅节点的 `udp: false` / `xhttp` / `packet-up` / Host+SNI、CF 最后
fallback、重复节点与覆盖拒绝、发布脚本的 `mihomo -t` 和 60 分钟回滚、
现有 Reality/主链测试，以及独立的 sing-box 升级失败门禁。

已知限制：

- 该路径仍依赖同一 VPS、Cloudflare 账号和 CF 可达性，不是异地灾备；
- 默认不承诺 UDP；CF 边缘 RTT 和 TLS-in-TLS 行为需真实客户端复测；
- 回源 443 的 Cloudflare 网段限制与现有直连订阅的关系必须在生产变更前
  明确选择，代码不会自动修改防火墙；
- `publish-cloudflare-subscription.sh` 在 AnyTLS/TUIC 已发布时拒绝。
  这是限制，不是待放宽的缺口；不要借版本对齐把 Cloudflare 或 Tunnel 节点
  加回默认订阅，也不要改写 extra overlay 的链序；
- 已安装的 Xray sidecar 不会因为 pin 更新而被重装；
- 本仓库没有、也不会从开发机执行 SSH、DNS、Cloudflare 或生产发布操作。

## 8. 禁止事项

- 不提交 UUID、XHTTP path、订阅 bearer、token、真实源站 IP 或工单中的真实
  hostname。
- 不橙云现有直连 hostname。
- 不同时部署 Tunnel+WS 与 XHTTP 两套受支持后端。
- 不在 timer 未结束时手工改订阅或删除 overlay state。
- 不用 `curl | sh`、不跳过证书校验、不把 CF path 当认证。
