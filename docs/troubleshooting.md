# Troubleshooting

## Mihomo 显示 Timeout

不能只看服务 `active` 或“UDP 包到达”。依次检查：

```bash
systemctl status sing-box sing-box-trojan nginx hy2-port-hopping
ss -lntup
nft list table inet edge_hy2_port_hopping
nstat -az UdpRcvbufErrors UdpSndbufErrors
journalctl -u sing-box -u sing-box-trojan --since '10 minutes ago'
```

抓包时需要同时观察入站和服务端响应，并记录 UDP 包尺寸、源端口变化及时间差。若同一服务在不同运营商表现不同，优先判断路径故障，不要先修改主配置。

## Port Hopping 更新失败

若客户端报 `cannot parse 'hop-interval' as int`，将值改为整数，例如：

```yaml
hop-interval: 20
```

## fallback 未回切

- 确认两个节点的 health check 均成功。
- 记住 `interval` 决定重新探测节奏。
- `profile.store-selected` 可能恢复同名组的旧状态；隔离诊断可使用临时新组名。
- 切换只作用于新连接，旧连接不会自动迁移。

## 重启后检查

确认所有 unit `enabled` 且 `active`，GRO/UDP buffer 等既有兼容设置仍然生效，并把 `nstat` 的重启后数值作为新基线。
