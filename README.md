# edge-infra

可复现、可审计、可迁移的个人 edge/network infrastructure 配置模板。

当前已验证的 V1 拓扑包含：

- Hysteria2：UDP 443，主入口
- Hysteria2 Port Hopping：UDP 20000-20031 重定向至 UDP 443
- Trojan/TLS：TCP 8443，异构备用入口
- nginx：TCP 443，HTTPS 静态订阅
- Mihomo fallback：`HY2 -> HY2-Hop -> Trojan`

仓库只保存模板和运维文档，不保存生产密码、Token、证书私钥、真实订阅文件或服务器备份。

## 快速开始

1. 复制 `env/secrets.env.example` 到仓库外的安全位置并填写实际值。
2. 根据 `docs/deployment.md` 将模板渲染到目标主机。
3. 执行 `scripts/verify.sh` 检查模板和敏感信息门禁。
4. 部署后执行 `scripts/health-check.sh`，再用真实客户端分别测试 UDP 和 TCP 路径。

## 文档

- [架构](docs/architecture.md)
- [部署](docs/deployment.md)
- [回滚](docs/rollback.md)
- [故障排查](docs/troubleshooting.md)
- [节点端口规划](nodes/us-west/ports.md)

## 安全边界

- `.example` 文件中的 `${...}` 均为占位符。
- 不要把生产 `/etc/sing-box/*.json` 或 `/var/www/sub/*.yaml` 复制进仓库。
- 私有仓库也不得提交 secret。
- 修改防火墙前必须先确认当前 SSH 端口和已有放行规则。
