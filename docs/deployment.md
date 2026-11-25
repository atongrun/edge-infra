# Deployment contract

## One-key install

`sudo ./install.sh` from a reviewed checkout is the supported interactive path.
It prompts for the minimal public inputs, auto-detects `PUBLIC_IPV4`, writes
root-only configs outside the repository, then runs the base installer and the
Reality overlay so the finished host matches the reference topology
(`主链路`: Reality → Trojan → HY2 → HY2-Hop). It is a thin orchestrator over
the two non-interactive phases below; it does not bypass preflight, rollback
safety, or the manifest checks. If the base phase succeeds but the overlay
phase fails, the host is base-only and must not be reported as fully deployed;
repair and retry the overlay or deliberately run base rollback.

## Preflight

`edge-infra preflight` is read-only and is called again by `install`. It requires:

1. Ubuntu 22.04/24.04 and amd64/arm64.
2. Root execution and an active SSH session, unless a verified console explicitly uses `--allow-console`.
3. One default IPv4 interface, or an explicit `NETWORK_INTERFACE`.
4. Both domains resolving to the exact configured `PUBLIC_IPV4`.
5. TCP 80/443/Trojan and UDP 443/hopping ports unused.
6. No existing edge-infra paths, units, certificate lineage or nftables table.
7. No existing nginx declaration for TCP 80/443.
8. If UFW is active, a provable allow rule for the current SSH port.

Any uncertainty stops deployment without mutation.

## Installation transaction

After `--yes`, installation performs these ordered phases:

1. Capture listeners, packages, systemd, UFW and nftables evidence under a root-only timestamped backup.
2. Install required packages, including vnStat, from Ubuntu APT repositories.
3. Download the pinned official sing-box release over HTTPS and verify its pinned SHA256, then symlink `/usr/local/bin/sing-box` to the pinned binary so the optional Reality overlay can locate it.
4. Generate HY2/Trojan passwords and a 192-bit subscription path token.
5. Render root-only sing-box configs, Mihomo subscription, nftables and systemd units.
6. When UFW is active, open only comment-scoped TCP 80 before ACME; bootstrap nginx, obtain a SAN certificate with Certbot webroot HTTP-01, then render the final HTTPS site.
7. Add comment-scoped UFW rules only when UFW was already active and SSH allow was proven.
8. Create the dedicated traffic header snippet, validate nginx, then enable the
   hourly vnStat updater without restarting any sing-box service.
9. Validate sing-box, nginx and nftables before enabling isolated services.
10. Write managed-file hashes and run `verify`.

The traffic header maps public-interface RX to `upload` and TX to `download`.
The public install config supplies its exact quota and billing direction; the
default is 500 GB decimal with both directions, while the audited DediOne
500 GiB profile is an explicit host-specific override. vnStat uses the VPS
calendar month and cannot reconstruct traffic from before its first
installation; the provider portal remains the billing authority.

An error after transaction state is created triggers best-effort rollback of edge-infra-owned objects. APT packages and the audit backup are preserved.

## Upstream supply chain

`versions.env` pins sing-box 1.14.4, the latest stable SagerNet release, for each supported architecture. v1.15 prereleases are excluded. The checksums are the SHA256 of `sing-box-1.14.4-linux-amd64.tar.gz` and `sing-box-1.14.4-linux-arm64.tar.gz` from the [v1.14.4 release](https://github.com/SagerNet/sing-box/releases/tag/v1.14.4), not the glibc or musl variants. `env/resilience-versions.env.example` repeats those bytes as `UPGRADE_SING_BOX_*` for the legacy upgrade and pins Xray-core 26.11.9 separately. Upgrades must change a version and both of its checksums together.

The project itself should be installed from a reviewed Git tag or GitHub Release. Do not advertise a moving `main` branch as a stable release and do not offer `curl | sudo sh` instructions.

## Firewall behavior

`FIREWALL_MODE=auto` does not mean "enable UFW":

- active UFW + proven SSH allow: add only `edge-infra` comment-scoped rules, with TCP 80 opened before the ACME request;
- inactive/missing UFW: leave it unchanged and report that firewall management was skipped;
- active UFW + uncertain SSH allow: fail closed.

Cloud firewall/security-group rules are outside the host and must be opened separately.
