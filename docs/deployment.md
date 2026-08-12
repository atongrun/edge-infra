# Deployment

## 前置门禁

1. 确认 Ubuntu、架构、接口名、当前 SSH 端口、UFW 状态和监听端口。
2. 创建 root-only 时间戳备份，保存配置、unit、UFW、nftables、监听和 enable 状态。
3. 确认 TCP 8443 与 UDP 20000-20031 未被占用。
4. 使用目标 sing-box 和 Mihomo 版本校验 schema，不直接照搬旧教程。

## Trojan/TLS

1. 用至少 32 字节 CSPRNG 生成密码，写入生产 `/etc/sing-box/trojan.json`；权限 `0600 root:root`。
2. 安装 `systemd/sing-box-trojan.service` 到 `/etc/systemd/system/`。
3. 安装证书续期 hook，并保持 `0700 root:root`。
4. 在确认 SSH 放行后，仅开放 `8443/tcp`。
5. 执行配置检查、daemon-reload、enable/start，并验证 TLS/SNI 和真实客户端连接。

## HY2 Port Hopping

1. 根据真实接口名修改 nftables 模板中的 `iifname`。
2. 安装 nftables 文件和独立 systemd unit；不要启用全局 `nftables.service`。
3. 在确认 SSH 放行后，仅开放计划范围 `20000:20031/udp`。
4. 启用 service，使用 `nft list table inet edge_hy2_port_hopping` 验证计数。

## Mihomo

渲染 `mihomo/edge.example.yaml` 中的域名和密码。Android/旧版 Mihomo 的 `hop-interval` 需要整数；已验证兼容值为 `20`，不要写成 `15-30`。

发布订阅前先用目标 Mihomo 版本加载完整 YAML。真实验证至少覆盖两类网络、三个节点、fallback 故障切换、恢复回切和 VPS 重启。
