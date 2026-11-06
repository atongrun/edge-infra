# edge-infra 备用入口与内核升级实施方案

日期：2026-11-06。状态：实施设计；不是部署完成记录。

## 1. 目标、授权与完成标准

增加一条 Mihomo 无需直连源站公网 IP 的 Cloudflare 备用路径；保留现有
Reality、Trojan、HY2、HY2-Hop 的行为。把备用入口建设和主内核升级作为两个
独立变更，分别验收、分别回滚。

本方案沿用既有生产门禁执行：

- 可以立即检查本地代码、实现脚本/模板/测试、准备部署包与回滚方案，并通过
  已有 SSH alias 做只读现网核查。
- 修改生产配置、防火墙、DNS、订阅、服务、二进制或 IP 前，先完成所有不依赖
  生产变更的工作，给出具体 diff、影响范围、验收/回滚步骤，再请求上线确认。
- 不创建收费资源，不更换 IP，不提交或推送代码，除非后续明确授权。
- 权限允许后持续执行至验收完成；缺少 CF 权限/token 时先完成独立代码工作，
  使用安全的凭据输入渠道，不要求把 token、UUID、订阅 bearer URL 贴进聊天。

本次交付包括：可执行且可重入的独立 CF overlay、可回滚的内核升级流程、
五节点订阅集成、测试、部署说明和准确的完成/未验证清单。未做实机验收时
只能标记“待部署/待验收”，不能宣称已具备生产保底能力。

## 2. 已知基线与必须现场确认的内容

本地仓库 versions.env 固定 sing-box 1.13.18 及 amd64/arm64 SHA256。
基础安装器拒绝已有安装，不可重跑它来升级。Reality overlay 使用固定四节点
顺序的生成与检查逻辑；基础模板不含 Reality，二者需要分别覆盖。

HY2-Hop 已有实现。私有历史验收见 HANDOFF.md 及其链接；2026-10-18 记录了
legacy 服务/规则和真实客户端成功。历史不证明当前状态，不能只按新安装器
表名查不到就新建第二套规则。F50 的分组名称和 provider 结构可能不同于模板。

实施者先核查：

1. Git 状态、本地 AGENTS 指令、共享 memory 契约；保留无关修改。
2. 通过现有 SSH alias 确认主机身份。读取各 unit 的实际 ExecStart、运行中
   可执行文件/版本、配置路径、用户权限、共享软链接和证书 reload hook。
3. 只读查看 TCP/UDP 监听、现有防火墙、legacy/new hopping 表、接口匹配和
   计数；记录是否存在重复转发规则。不得为调查而 reload/reset 计数。
4. 订阅真实生成路径、持久化 state、发布位置和原子替换机制；不输出凭据。
5. 手机和 F50 的实际核心版本、provider、组关系、DNS bootstrap 与现有
   路由。保留原有 Tailscale、DIRECT 和稳定链路规则。
6. CF zone 管理权限、可用专用 hostname、Tunnel 凭据供给方式，以及订阅
   域名是否依赖源站直连。地址和事故证据只放私有执行记录。

TCP 故障时间与恢复日期来自用户观测，未由本方案复测。UDP QoS 是假设，
不是结论；MTU、丢包、NAT、路由均未排除。本轮不把跳端口当成独立故障域。

## 3. 首选架构

采用官方 cloudflared 独立守护进程，不以嵌入式 Tunnel 作为第一版依赖：

```text
手机/F50 Mihomo
  → VLESS over WebSocket + TLS，专用 hostname:443
  → Cloudflare 边缘（TLS 终止，WebSocket）
  → Cloudflare Tunnel（cloudflared 主动连接，强制 HTTP/2）
  → http://127.0.0.1:<CF_ORIGIN_PORT>
  → 独立 sing-box VLESS-WS 进程
  → 目标网站
```

入口实现约束：

- 新建专用 hostname，使用 Tunnel 的 DNS 路由，不把现有直连域名改橙云。
- Tunnel 发布类型为 HTTP，映射到同机回环 WS 入站；不是 tcp:// 服务。
- 本机入站仅监听 127.0.0.1，端口通过显式配置和冲突检测确定；无需新增
  公网入站端口。TLS 在 CF 边缘终止，Tunnel 已加密，同机回环段使用 HTTP。
- VLESS 使用独立随机 UUID、固定且两端一致的 WS path；不使用 Reality、
  Vision flow 或 early-data 作为首版依赖。保留严格客户端证书校验。
- Mihomo 节点使用 type: vless、network: ws、port: 443、tls: true，
  server/servername/WS Host 为专用 hostname，ws-opts.path 与入站一致。
  UDP/packet-encoding 先做版本兼容验证；未验收前不承诺 UDP 可用。
- 不将随机 WS path 当作认证；认证由 UUID 提供。CF 入口不能套浏览器交互
  登录或挑战页面来要求无人值守 Mihomo 完成人机交互。
- cloudflared 固定官方稳定版本与架构校验值，使用受保护 token 文件或官方
  支持的安全凭据机制；不把 token 放在命令行、Git、日志或聊天输出中。
- 独立配置、unit、日志和状态目录；分别运行低权限用户。根据实际二进制
  支持的参数实现 unit，不能猜测 token-file 或 HTTP/2 参数。
- 首版独立 VLESS-WS 进程使用单独版本目录内的已校验二进制，不依赖主链
  current 软链接。可用 1.13.18 验证现有 WS 支持；配置不兼容时先查官方
  schema/迁移记录，禁止静默替换主链。CF 链路与主链升级必须能独立回滚。
- HTTP/2 控制 VPS↔CF 隧道，不解决大陆到 CF 的可达性；需要手机和 F50 实测。

嵌入式 cloudflared inbound 是备选：只有独立实例端到端通过后才可改选；
必须使用独立 1.14.4 二进制/配置/unit，避免主链回退 1.13.18 时一起失效。
第一版不同时实现两套 Tunnel 管理方式。

## 4. 代码与文件级交付

遵循现有 overlay 结构；以下新增文件名可随仓库约定调整，职责不可省略。

| 文件/区域 | 要求 |
| --- | --- |
| scripts/cloudflare-overlay.sh | preflight、install、status、verify、rollback；显式确认门禁；只操作自有资源；失败局部撤回；重复运行不产生重复节点/服务 |
| env/cloudflare.env.example | 只列公开占位配置；严格解析未知/重复 key；凭据文件路径、hostname、origin port、WS path、架构/版本参数 |
| templates/sing-box/cloudflare-vless-ws.json | 回环 VLESS-WS 入站、认证、必要日志配置和 direct 出站 |
| templates/systemd/ | 独立 cloudflared 与 VLESS-WS unit；启动前校验、合理重启策略、权限、停止顺序 |
| versions.env / 独立版本清单 | 主 sing-box 两架构校验和；cloudflared 和独立 WS runtime 的固定版本/校验和；不得与主链回滚耦合 |
| scripts/reality-overlay.sh | 渲染和验证可选第五节点；重复应用不重复；CF 未启用时仍保持四节点；回滚/重新生成不能丢失已启用扩展 |
| templates/mihomo/edge.yaml 与渲染代码 | 保持基础无 Reality 安装兼容；由明确的 CF enable/state 控制注入，不能让所有新安装默认引用不存在的 CF 节点 |
| scripts/upgrade-sing-box.sh | 只升级已有目标服务；版本校验、配置检查、切换、局部重启、回滚；不借用新装流程 |
| health-check / verify / CLI | 按已有 CLI 合约接入可选组件状态；CF 未安装不报主链故障；不输出秘密 |
| tests/ | 新功能失败路径、幂等、四/五节点、架构 checksum、权限、部分安装撤回、主链回滚不影响独立 CF、overlay 生命周期兼容 |
| docs/deployment.md、rollback.md、testing.md | 操作步骤、实际命令、前置条件、配置示例、验收矩阵、卸载顺序和已知限制 |

不要只修改正常安装路径。特别检查 Reality 重装/回滚、基础卸载、证书续期、
订阅重生成对 CF 的影响。选择并文档化依赖顺序；有依赖时明确拒绝危险操作，
不留下无效组引用或悄悄删除备用入口。保留旧配置的预期行为。

## 5. 订阅与切换策略

CF 启用并通过单节点验收后，主 fallback 顺序为：

Reality → Trojan → HY2 → HY2-Hop → Cloudflare-VLESS-WS。

继续使用 fallback；不改为 url-test。具体 interval/timeout 等先保留现场基线，
测量实际切换耗时再决定是否调整，不把检测间隔当作恢复时间保证。长连接
不会因 fallback 自动无缝迁移；验收记录应用重连行为。

更新流程为生成候选 → 对目标 Mihomo 版本执行配置检查 → 检查节点唯一性、
组引用和顺序 → 原子发布 → 客户端刷新并验收。失败恢复原文件及有效配置，
不能只恢复磁盘文件却忘记运行中配置。

首轮不迁移订阅域名：先明确记录其是否依赖源站直连，并在正常网络提前下发
五节点配置，保留本地有效缓存。源站直连失效时重新获取订阅不在默认保证内；
若用户要求此能力，再单独设计 bearer 路径、缓存与访问日志保护后确认实施。
CF 节点 hostname 的 DNS bootstrap 不能依赖正在解析的主代理，避免启动环路。

## 6. 主内核升级事务

目标 1.14.4，执行时复核官方 release/安全与迁移说明；若出现应改变目标版本
的实质原因，说明后调整方案，不静默追随 latest。

1. 为 amd64/arm64 核验官方发行包及 SHA256，更新固定版本与校验值；验证
   下载、解包、错误校验和拒绝、架构选择。不得仅修改版本字符串。
2. 盘点所有实际运行 sing-box 进程和各 unit，区分共享二进制、独立 CF
   runtime、手工 legacy 布局及受管布局。无法识别布局时拒绝盲目写入。
3. 私有备份现有二进制、配置、unit/drop-in、软链接、相关 state 和订阅，
   记录权限与校验值；准备可独立执行的窄范围回滚脚本。
4. 下载到版本目录，用新二进制检查全部受影响配置及必要证书读取权限。
   如需配置迁移，分别保留旧版/新版配置，回滚不能只回退二进制。
5. 在生产确认后，使用与实际布局匹配的原子切换；绝不原地覆盖运行中的
   可执行文件。只重启受影响服务；记录中断窗口与依赖顺序。
6. 核验运行中进程的实际版本而非仅 shell 的 version，监听、独立 SSH
   新会话以及所有现有节点的外部 HTTPS/UDP 行为。
7. 设置经过验证且不依赖当前 SSH 会话的限时回滚机制，只有验收通过后取消。
   失败恢复旧二进制、配置、unit/链接和运行状态；不撤销独立 CF 路径。

## 7. 分阶段执行与批准点

A. 立即实施本地代码与测试，并完成只读现网核查；不得打印完整敏感配置。
准备具体变更清单，至少包括 CF hostname/服务映射（敏感值私下展示）、部署
文件、进程、出站依赖、预计中断、订阅变化、备份位置和回滚命令。

B. 请求批准 CF 生产试点；批准后才创建 Tunnel/DNS、安装独立服务。先用
隔离配置验证单节点，成功后原子更新五节点订阅并做故障切换演练。主链内核
此时保持原版。缺少 CF 账户能力时明确缺口，不假装已创建资源。

C. 单独展示主内核升级的具体包/校验值、配置检查、影响服务与回滚方案；
获得相应上线授权后执行升级事务。此前若用户已明确批准同一具体范围则
不重复询问。HY2-Hop 只有证实有故障才提出最小修复，不预设要改防火墙。

D. 回填私有部署记录及通用公共文档。准确区分本地实现、已测试、已部署、
客户端已验收、未验证；无授权不 commit/push，不写共享 memory。

## 8. 验收矩阵与失败处理

代码门禁：scripts/verify.sh、tests/run.sh、仓库 Bash syntax/ShellCheck；
按 CI 支持的 Ubuntu 22.04/24.04 运行相关检查。配置使用对应实际版本的
sing-box check / Mihomo 检查。Mac 无法执行的 Linux/unit 测试明确列为待验证，
不要把静态字符串匹配当作运行验收。

| 场景 | 必须取得的证据 |
| --- | --- |
| 单 CF 节点 | 手机、F50 各自实际核心 HTTPS 成功，证书正常，日志与连接路径确认为 CF |
| 直连 TCP 失效 | 隔离客户端阻断源站 TCP，观察 HY2/Hop 与 fallback 行为，不影响管理连接 |
| 所有直连失效 | 隔离客户端阻断源站 TCP+UDP，CF 接管新连接，测切换时间及多个 HTTPS 目标 |
| 真实路径 | 排除测试 Mac 流量嵌套 F50 现有代理；DNS 和连接证据显示没有直连源站 |
| 运行稳定性 | 至少 30 分钟持续请求与长连接观察，覆盖空闲后重连；说明不代表长期保证 |
| 恢复 | 移除仅测试用阻断，记录新连接回切与已有连接行为；清理测试资源 |
| CF 故障 | 停止测试 CF 服务或使用隔离故障注入，主链仍可用；撤销 CF overlay 后原订阅有效 |
| HY2-Hop | 实际高端口数据与服务端计数增长，跨多个 hop 周期的请求；不用一次 204 代替 |
| UDP | 若声明 CF 支持 UDP，进行真实 UDP payload/DNS 测试；否则明确仅验证 TCP 应用 |
| 升级/回滚 | 运行版本证据、配置验证、全部旧节点复测、独立 CF 持续可用；回滚后旧配置可运行 |

故障演练不得修改生产 VPS 的全局防火墙或把自己锁出管理入口；先准备隔离
测试范围和清理方案。CF 节点失败时不发布五节点配置；订阅失败恢复旧版；
主升级失败执行事务回滚。服务重启/机器重启的自动启动验证分开记录，生产
重启另行明确授权，不为完成检查擅自重启整机。

## 9. 范围外与资料

不另开 Xray，不改 Reality dest/端口，不新增 AnyTLS/TUIC/salamander，
不引入中转/AAAA，不更换 IP，不动已有 Tailscale 和 Nowhere 路由。
CF 路径绕开客户端直连源站这一故障域，但仍依赖同一 VPS、CF 可达性和账号，
不是异地灾备。现有直连 DNS 可能公开源站 IP，不宣称源站完全隐藏。

本方案不保存真实服务器地址、凭据或订阅入口。Memory Check：这是项目实施
计划，应该留在项目仓；本轮无需写入共享长期 memory。

官方依据（实施时复核具体版本行为）：

- https://github.com/SagerNet/sing-box/releases/tag/v1.14.4
- https://sing-box.sagernet.org/configuration/inbound/cloudflared/
- https://sing-box.sagernet.org/configuration/inbound/vless/
- https://sing-box.sagernet.org/configuration/shared/v2ray-transport/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/protocols/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
- https://developers.cloudflare.com/network/websockets/
- https://wiki.metacubex.one/config/proxies/vless/
- https://wiki.metacubex.one/config/proxy-groups/fallback/
