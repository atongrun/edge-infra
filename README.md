# edge-infra

Auditable, rollback-oriented personal edge infrastructure for a fresh Ubuntu VPS.

`edge-infra` deploys one deliberately small architecture:

```text
Mihomo fallback
  1. Hysteria2          UDP 443
  2. Hysteria2 Hop      UDP 20000-20031 -> UDP 443
  3. Trojan/TLS         TCP 8443

HTTPS subscription      nginx TCP 443
ACME + redirect         nginx TCP 80
```

It is a personal single-user deployment, not a panel, multi-user proxy service, billing system, or protocol collection.

## Safety status

- Production passwords and the subscription bearer path are generated on the VPS with `openssl rand`.
- Secrets are stored only in `/etc/edge-infra/secrets.env` with mode `0600`.
- sing-box is downloaded from the official SagerNet GitHub Release at a pinned version and verified against pinned SHA256 values.
- Ubuntu packages come from configured APT repositories; no author-controlled endpoint returns root shell code.
- Preflight fails on occupied ports, existing managed paths, existing certificate lineage, ambiguous network interfaces, DNS mismatch, or firewall/SSH uncertainty.
- nftables changes are isolated in `table inet edge_infra_hy2_hopping`; the installer never flushes the global ruleset or enables the global nftables service.
- Services remain isolated as separate systemd units.

The repository and Git history contain templates and documentation only. Run `./scripts/verify.sh` to repeat the public-readiness secret scan.

## Supported hosts

- Ubuntu 22.04 or 24.04
- amd64 or arm64
- A fresh VPS with root or sudo access
- One unambiguous default IPv4 interface
- Two DNS names, each with exactly one A record resolving to the VPS IPv4 address
- Inbound TCP 80/443/8443 and UDP 443/20000-20031 available

V1 intentionally fails closed on a host already using these ports or managed paths. It is not an in-place migration tool.

## Quick start

Do not pipe a remote script into root. Clone a reviewed tag or release locally:

```bash
git clone https://github.com/atongrun/edge-infra.git
cd edge-infra
git checkout <release-tag>
```

Create a root-only config outside the repository:

```bash
sudo install -m 0600 env/install.env.example /root/edge-infra.env
sudo editor /root/edge-infra.env
```

The config contains only public deployment inputs:

```ini
EDGE_DOMAIN=edge.example.com
SUB_DOMAIN=sub.example.com
PUBLIC_IPV4=203.0.113.10
ACME_EMAIL=admin@example.com
```

Run the same preflight used by installation, review its output, then install:

```bash
sudo ./bin/edge-infra preflight --config /root/edge-infra.env
sudo ./bin/edge-infra install --config /root/edge-infra.env --yes
```

After installation:

```bash
sudo edge-infra status
sudo edge-infra verify
sudo edge-infra health
```

`status` prints the generated subscription URL. Treat that URL as a credential: its random path exposes the generated node passwords to anyone who has it.

## Lifecycle CLI

| Command | Purpose |
|---|---|
| `preflight --config FILE` | Read-only host, DNS, SSH, port, firewall and conflict checks |
| `install --config FILE --yes` | Backup, install, render, issue TLS, start and verify |
| `status` | Show installed topology and systemd state without passwords |
| `verify` | Check file integrity, configs, listeners, services, nftables and local HTTPS |
| `health` | Add DNS, certificate lifetime, TLS and restart/error counters |
| `rollback --yes` | Remove the last edge-infra transaction and retain its backup |
| `uninstall --yes` | Alias for rollback |

If a managed file changed after installation, rollback fails closed. Review the changes and use `--force` only when removal is intentional.

## What installation changes

Managed paths:

```text
/etc/edge-infra/
/etc/systemd/system/edge-infra-*.service
/etc/nginx/sites-{available,enabled}/edge-infra.conf
/etc/letsencrypt/renewal-hooks/deploy/edge-infra
/var/lib/edge-infra/
/var/backups/edge-infra/<timestamp>/
/var/www/edge-infra-{acme,subscription}/
/usr/local/lib/edge-infra/
/usr/local/sbin/edge-infra
```

The installer also creates one Let's Encrypt certificate lineage named after `EDGE_DOMAIN`. OS packages installed from APT are intentionally left installed during rollback because removing shared packages is unsafe.

If UFW is already active, the installer first proves the current SSH allow rule, then adds only comment-scoped `edge-infra` rules. If UFW is inactive, it remains inactive and no host firewall rules are added. Provider security groups remain the operator's responsibility.

## Rollback

```bash
sudo edge-infra rollback --yes
```

Rollback stops only `edge-infra-*` units, deletes only its own nftables table and UFW comments, removes its generated certificate/configuration, restores the nginx default symlink when the transaction removed it, and preserves `/var/backups/edge-infra/<timestamp>/` for audit.

## Documentation

- [Architecture and ownership](docs/architecture.md)
- [Deployment contract](docs/deployment.md)
- [Optional Reality candidate overlay](docs/reality-candidate.md)
- [Rollback and uninstall](docs/rollback.md)
- [Security model](docs/security.md)
- [Testing and release gates](docs/testing.md)
- [Troubleshooting](docs/troubleshooting.md)

## Non-goals

- Web UI or management panel
- Multi-user accounts or traffic accounting
- Automatic SSH changes
- Global nftables ownership
- Aggressive sysctl, congestion-control, GRO or MTU tuning
- Automatic migration of an existing proxy/nginx deployment

## License

[MIT](LICENSE)
