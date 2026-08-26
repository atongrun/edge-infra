# edge-infra

A small, auditable proxy stack for a fresh Ubuntu VPS. It deploys a single
user Mihomo subscription with a TCP-first fallback chain.

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

## Recommended VPS

This stack is deployed and tested on [DediOne Los Angeles (CMIN2+CUII)](https://dedione.com/aff.php?aff=457):
$29.99/year gets 1 vCPU, 1 GB RAM, 10 GB NVMe, 500 GB/month traffic, and a
200 Mbps port, measured at ~207 ms average latency, 0% packet loss, and
~50 Mbps throughput, with stable access to GitHub, Codex, Claude, Telegram,
and X. It is an affiliate link.

## Installation

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
Install and configure edge-infra on this fresh VPS. Read and follow the full
installation guide step by step:
https://raw.githubusercontent.com/atongrun/edge-infra/v0.1.1/docs/guide/installation.md

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
git checkout v0.1.1
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
curl -fsSL https://raw.githubusercontent.com/atongrun/edge-infra/v0.1.1/docs/guide/installation.md
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
vnStat month usage against a 500 GB total; no second URL or client plugin is
required.

The repository checks can be run before deployment:

```bash
./scripts/verify.sh
./tests/run.sh
```

## Rollback

Remove only the Reality overlay:

```bash
sudo edge-infra-reality rollback --yes
```

Remove the complete deployment:

```bash
sudo edge-infra rollback --yes
```

Rollback preserves timestamped backups and fails closed if managed files were
changed after installation. Use `--force` only after reviewing such changes.

## Security properties

- Secrets are generated on the VPS and stored root-only.
- sing-box is downloaded from the official release and checked against pinned
  SHA256 values.
- Preflight fails closed on occupied ports, conflicting managed paths, DNS
  mismatch, and firewall/SSH uncertainty.
- nftables changes use an isolated table and never flush the global ruleset.
- The installer does not use `curl | sh`.

## Documentation

- [Full installation guide](docs/guide/installation.md)
- [Architecture and ownership](docs/architecture.md)
- [Deployment contract](docs/deployment.md)
- [Reality overlay](docs/reality-candidate.md)
- [Rollback](docs/rollback.md)
- [Security model](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)

## License

[MIT](LICENSE)
