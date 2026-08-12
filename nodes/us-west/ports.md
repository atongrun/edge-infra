# Port plan

| Port | Transport | Purpose |
|---|---|---|
| current SSH port | TCP | Administration |
| 443 | UDP | Hysteria2 |
| 443 | TCP | HTTPS subscription |
| 8443 | TCP | Trojan/TLS fallback |
| 20000-20031 | UDP | Hysteria2 Port Hopping redirect |

TCP 443 与 UDP 443 不冲突。防火墙只开放上述必要入口；上游安全组若存在，需要同步采用相同最小范围。
