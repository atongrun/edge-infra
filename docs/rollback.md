# Rollback

回滚只删除 V1 新增能力，不修改主 HY2 配置和原 nginx 订阅站点。

1. 先把客户端订阅恢复到变更前备份。
2. `systemctl disable --now sing-box-trojan.service`
3. 删除 UFW 的 `8443/tcp` 放行规则。
4. `systemctl disable --now hy2-port-hopping.service`
5. 删除 UFW 的 `20000:20031/udp` 放行规则。
6. 确认独立 nftables table 已删除；若仍存在，仅执行：
   `nft delete table inet edge_hy2_port_hopping`
7. 删除新增证书 hook、独立 unit 和独立配置，执行 `systemctl daemon-reload`。
8. 验证 SSH、原 HY2 UDP 443、nginx TCP 443、订阅、UFW 与监听状态。

不要 flush nftables，不要以恢复 `/etc/sing-box/config.json` 作为回滚步骤；该文件在此改造中本就不应修改。
