# edge-infra

A small, auditable proxy stack for a fresh Ubuntu VPS. It deploys a single
user Mihomo subscription with a TCP-first fallback chain, plus an
[optional Nowhere backup relay](#optional-nowhere-backup-relay) for applications
that need a separate SOCKS5 entry point.

## Architecture

```text
Mihomo 主链路 fallback
  1. DediOne-Reality   VLESS + Reality + Vision   TCP 9443
  2. DediOne-Trojan    Trojan/TLS                TCP 8443
  3. DediOne-HY2       Hysteria2                 UDP 443
  4. DediOne-HY2-Hop   Hysteria2 port hopping    UDP 20000-20031 -> UDP 443

HTTPS subscription    nginx                    TCP 443
Monthly traffic       vnStat + response header hourly
ACME challenge        nginx                    TCP 80
```

Reality and Trojan provide heterogeneous TCP fallbacks. HY2 and HY2-Hop remain
UDP/QUIC paths. The published subscription contains one main group, ordered
exactly as shown above.

## Optional Nowhere backup relay

Nowhere adds an independent VPS-side **Portal** and a client-side **Vector**.
Vector exposes a local SOCKS5 proxy and connects to Portal over TCP or QUIC:

```text
Selected application
  -> Vector SOCKS5 on 127.0.0.1:1089
  -> Nowhere TCP or QUIC -> Portal on TCP/UDP 10443 -> Internet
```

This component is **opt-in**: `install.sh` does not install it, and it is not
added to the Mihomo subscription or fallback chain. Portal has its own service,
user, configuration, credentials, certificate copy, resource limits and
rollback. A Portal on the same VPS adds a protocol option; it does not provide
another host or exit route.

### Server setup

Use the reviewed checkout described under [Installation](#installation).
Prepare a matching Let's Encrypt certificate and allow the selected TCP and
UDP ports in the cloud firewall (both default to `10443`). Read the
[Nowhere guide](docs/nowhere.md) for prerequisites and security boundaries,
then copy and edit the public host/certificate settings outside Git:

```sh
sudo install -m 0600 env/nowhere.env.example /root/nowhere.env
sudoedit /root/nowhere.env
sudo scripts/nowhere-overlay.sh preflight --config /root/nowhere.env
sudo scripts/nowhere-overlay.sh install --config /root/nowhere.env --yes
sudo scripts/nowhere-overlay.sh verify
```

### Client usage

Prepare a verified native Nowhere v3.0.1 binary and a user-owned `0600` client
configuration outside Git, following the [client guide](docs/nowhere.md#client-boundary).
Start one foreground Vector with either carrier:

```sh
scripts/nowhere-vector.sh --config /absolute/path/client.env tcp
# Or use QUIC:
scripts/nowhere-vector.sh --config /absolute/path/client.env quic
```

Set the chosen application's SOCKS5 proxy to `127.0.0.1:1089` (the default).
Ctrl-C stops Vector; the launcher does not change the system proxy. This
integration uses a separate Vector process rather than a native Mihomo node.

Verify real HTTPS traffic through Vector; server-side `verify` checks only
the local service. Behind a transparent proxy router, also verify that Portal
traffic takes the intended direct path and does not loop through the primary
proxy. See the guide for scoped routing and client configuration, and
[Rollback](#rollback) to remove only this optional component.

## Recommended VPS

This stack is deployed and tested on [DediOne Los Angeles (CMIN2+CUII)](https://dedione.com/aff.php?aff=457):
$29.99/year gets 1 vCPU, 1 GB RAM, 10 GB NVMe, 500 GB/month traffic, and a
200 Mbps port, measured at ~207 ms average latency, 0% packet loss, and
~50 Mbps throughput, with stable access to GitHub, Codex, Claude, Telegram,
and X. It is an affiliate link.

## Installation

This remains a pre-release until the disposable fresh-VPS lifecycle tests in
[the release gates](docs/testing.md) pass. The commands below pin a reviewed
revision containing the client DNS/IPv6 fixes, lifecycle hardening and optional
Nowhere support; the older v0.1.1 tag does not contain these fixes.

Supported hosts:

- Ubuntu 22.04 or 24.04;
- amd64 or arm64;
- a fresh VPS with root or sudo access;
- two DNS A records pointing only to the VPS public IPv4;
- TCP 80, 443, 8443 and 9443, plus UDP 443 and 20000-20031 available.

### For Humans

**Strongly recommended: let an LLM agent install this for you.** It can read
the complete guide, run preflight, ask for the required public values, and
verify the deployment without relying on manually edited configuration files.

Paste this prompt into Claude Code, Codex, Cursor, Cline, or another capable
agent running on the new VPS:

```text
Install and configure edge-infra on this fresh VPS.
Reviewed revision: 818a4c6d4bf2b9d8c7d268e8ea3d3c69a651c5fc
Set EDGE_INFRA_REVISION to that exact SHA. Read and follow the full
installation guide step by step:
https://raw.githubusercontent.com/atongrun/edge-infra/818a4c6d4bf2b9d8c7d268e8ea3d3c69a651c5fc/docs/guide/installation.md

Deploy the complete topology: DediOne-Reality first on TCP 9443,
DediOne-Trojan on TCP 8443, DediOne-HY2 on UDP 443, and DediOne-HY2-Hop on
UDP 20000-20031. Serve the HTTPS subscription through nginx on TCP 443.
Run preflight before every mutating phase. Do not claim success until local
verification and an external client smoke test pass. Ask me only for values
that cannot be discovered safely, such as domain names, public IPv4, and ACME
email. Do not invent secrets or pipe an unreviewed remote script into root.
If anything fails, stop and report the exact error and the safest recovery
command.
```

If you prefer to run the installer yourself:

```bash
git clone https://github.com/atongrun/edge-infra.git
cd edge-infra
git checkout 818a4c6d4bf2b9d8c7d268e8ea3d3c69a651c5fc
sudo ./install.sh
```

The installer asks for the two domain names, public IPv4, ACME email, and
Reality target/SNI. It generates passwords and Reality credentials locally on
the VPS, writes root-only configuration files, runs both installation phases,
and prints the subscription URL after verification.

### For LLM Agents

Fetch the exact installation guide for the reviewed revision, then follow it
step by step:

```bash
curl -fsSL https://raw.githubusercontent.com/atongrun/edge-infra/818a4c6d4bf2b9d8c7d268e8ea3d3c69a651c5fc/docs/guide/installation.md
```

After cloning, the same guide is available at
`docs/guide/installation.md`. Do not guess the deployment procedure from a
partial README or skip preflight and verification.

## Verification

After installation:

```bash
sudo edge-infra status
sudo edge-infra verify
sudo edge-infra-reality verify
sudo edge-infra health
```

Import the printed subscription URL into Mihomo/Clash Verge and perform an
external smoke test. Treat the URL as a credential: do not commit it or expose
it in logs. Refreshing the existing subscription card shows the current
vnStat month usage against the configured quota (default 500 GB, decimal); no second URL or client plugin is
required.

The repository checks can be run before deployment:

```bash
./scripts/verify.sh
./tests/run.sh
```

## Rollback

Remove only the optional Nowhere overlay:

```bash
sudo scripts/nowhere-overlay.sh rollback --yes
```

Remove only the Reality overlay:

```bash
sudo edge-infra-reality rollback --yes
```

For a complete uninstall, first remove Nowhere and then Reality with the
commands above, skipping overlays that were not installed. Then remove the
base deployment:

```bash
sudo edge-infra rollback --yes
```

Rollback preserves timestamped backups and fails closed if managed files were
changed after installation. Use `--force` only after reviewing such changes.
The base rollback refuses to run while Reality remains installed, even with
`--force`, and does not remove the independent Nowhere overlay.

## Security properties

- Secrets are generated on the VPS and stored root-only.
- sing-box is downloaded from the official release and checked against pinned
  SHA256 values.
- Preflight fails closed on occupied ports, conflicting managed paths, DNS
  mismatch, and firewall/SSH uncertainty.
- nftables changes use an isolated table and never flush the global ruleset.
- The installer does not use `curl | sh`.

## Documentation

- [Optional independent Nowhere backup relay](docs/nowhere.md)
- [Client DNS and IPv6 routing](docs/client-egress.md)
- [Node optimization and acceptance](docs/node-optimization.md)
- [Full installation guide](docs/guide/installation.md)
- [Architecture and ownership](docs/architecture.md)
- [Deployment contract](docs/deployment.md)
- [Reality overlay](docs/reality-candidate.md)
- [Rollback](docs/rollback.md)
- [Security model](docs/security.md)
- [Host maintenance checklist](docs/hardening-checklist.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

[MIT](LICENSE)
