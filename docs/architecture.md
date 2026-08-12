# Architecture

```text
Mihomo fallback
  1. HY2          UDP 443
  2. HY2-Hop      UDP 20000-20031 -> UDP 443
  3. Trojan/TLS   TCP 8443

Subscription      nginx TCP 443
Administration    SSH current port
```

HY2 与 HY2-Hop 属于同一 UDP/QUIC 故障域。Port Hopping 只用于规避针对固定 UDP 端口或流的限制，不能替代异构 TCP fallback。Trojan 使用独立配置、独立 sing-box 实例和独立 systemd unit；它不修改主 HY2 inbound。

端口跳跃使用独立 nftables table，由独立 oneshot service 管理。它不会 flush 全局 ruleset，也不给 sing-box 增加 `CAP_NET_ADMIN`。

Mihomo fallback 的健康检查只影响新连接；已经建立的连接不会无缝迁移。客户端的 `profile.store-selected` 可能保留同名组的选择状态，诊断时要区分缓存选择与实时健康状态。
