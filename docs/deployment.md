# Deployment contract

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
3. Download the pinned official sing-box release over HTTPS and verify its pinned SHA256.
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
