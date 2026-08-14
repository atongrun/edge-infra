# Security model

## Secrets

The installer generates:

- 256-bit HY2 password;
- 256-bit Trojan password;
- 192-bit subscription bearer token.

They are stored in `/etc/edge-infra/secrets.env` as root-only data and rendered into root-only sing-box configs. The static YAML must be readable by nginx, so the random HTTPS path is the access boundary. Anyone with the subscription URL obtains node credentials; rotate by reinstalling or a future dedicated rotation command.

The repository must never contain real `.env`, subscription YAML, passwords, tokens, certificates, private keys, IPs or deployment domains. `scripts/verify.sh` scans both the worktree and reachable Git history for known credential patterns and environment residue.

## Root execution

Root is necessary for privileged ports, systemd, nginx, certificate paths and nftables. The supported workflow is clone, inspect, pin a release tag, then run the local file with sudo. Remote pipe-to-shell installation is intentionally unsupported.

## Firewall and SSH

The installer does not modify sshd, root login, users, SSH keys, UFW default policies or cloud security groups. With active UFW it refuses mutation unless the current SSH allow rule is provable.

## Network tuning

No sysctl, qdisc, congestion-control, GRO, GSO, TSO, MTU or PMTU setting is modified. `disable-mtu-discovery: true` is kept in the Mihomo HY2 nodes as a client compatibility guard, not as a global host optimization.

## Reporting

Do not paste `/etc/edge-infra/secrets.env`, the generated subscription URL or live rendered configs into a public issue. Redact domains, IPs, client addresses and certificates from diagnostics when privacy matters.
