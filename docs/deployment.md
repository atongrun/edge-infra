# Deployment contract

## One-key install

`sudo ./install.sh` from a reviewed checkout is the supported interactive path.
It prompts for the minimal public inputs, auto-detects `PUBLIC_IPV4`, writes
root-only configs outside the repository, then runs the base installer and the
Reality overlay so the finished host matches the live `la-vps` topology
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
2. Install required packages from Ubuntu APT repositories.
3. Download the pinned official sing-box release over HTTPS and verify its pinned SHA256, then symlink `/usr/local/bin/sing-box` to the pinned binary so the optional Reality overlay can locate it.
4. Generate HY2/Trojan passwords and a 192-bit subscription path token.
5. Render root-only sing-box configs, Mihomo subscription, nftables and systemd units.
6. When UFW is active, open only comment-scoped TCP 80 before ACME; bootstrap nginx, obtain a SAN certificate with Certbot webroot HTTP-01, then render the final HTTPS site.
7. Add comment-scoped UFW rules only when UFW was already active and SSH allow was proven.
8. Validate sing-box, nginx and nftables before enabling isolated services.
9. Write managed-file hashes and run `verify`.

An error after transaction state is created triggers best-effort rollback of edge-infra-owned objects. APT packages and the audit backup are preserved.

## Upstream supply chain

`versions.env` pins the sing-box version and official GitHub asset SHA256 for each supported architecture. Upgrades must change the version and checksum together and cite the upstream SagerNet release.

The project itself should be installed from a reviewed Git tag or GitHub Release. Do not advertise a moving `main` branch as a stable release and do not offer `curl | sudo sh` instructions.

## Firewall behavior

`FIREWALL_MODE=auto` does not mean "enable UFW":

- active UFW + proven SSH allow: add only `edge-infra` comment-scoped rules, with TCP 80 opened before the ACME request;
- inactive/missing UFW: leave it unchanged and report that firewall management was skipped;
- active UFW + uncertain SSH allow: fail closed.

Cloud firewall/security-group rules are outside the host and must be opened separately.
