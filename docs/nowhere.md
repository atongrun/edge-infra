# Independent Nowhere backup relay

This optional overlay adds a separate Nowhere v3.0.1 Portal. It is not part of
the base installer or Mihomo subscription. It owns TCP and UDP port `10443` by
default and leaves nginx `443`, Reality `9443`, Trojan `8443`, HY2 `443`, and
the hopping range untouched.

## Preconditions

- A Linux x86_64 or aarch64 VPS with an unused configurable TCP and UDP port.
- A public DNS name and an existing matching Let's Encrypt certificate under
  `/etc/letsencrypt/live/<NOWHERE_CERT_NAME>/`.
- The cloud security group admits the selected TCP and UDP ports. The overlay
  adds only its comment-scoped UFW rules when UFW is already active.
- Local shell users are trusted, or the host has an appropriate `/proc` policy.
  Upstream Nowhere takes its service URL on argv, and that URL includes the
  shared key. The overlay confines the service to a dedicated non-login user
  and keeps the runtime file root-only, but cannot hide argv from unrelated
  local users on a host that exposes every process command line.

## Install and verify

Copy `env/nowhere.env.example` outside Git and set the DNS name and certificate
name. The source certificate is copied into an overlay-owned directory so the
service never reads the shared base certificate files directly.

```sh
sudo scripts/nowhere-overlay.sh preflight --config /root/nowhere.env
sudo scripts/nowhere-overlay.sh install --config /root/nowhere.env --yes
sudo scripts/nowhere-overlay.sh status
sudo scripts/nowhere-overlay.sh verify
```

The installer pins Nowhere `v3.0.1` to GitHub Release asset digests for Linux
x86_64/aarch64, GNU/musl. It uses `tls=2`, `out=direct`, `morph=1`, and the
`memory` transport profile by default. `verify` confirms the local service,
listeners, permissions, and certificate copy; it does not establish that a
remote Vector, HTTPS payload, or a client routing policy works.

The systemd unit caps this optional component at `MemoryHigh=96M`,
`MemoryMax=128M`, `CPUWeight=20`, and `TasksMax=64`. Reaching a cgroup limit
can interrupt or restart this backup relay only; it is a containment boundary,
not a performance claim. Measure idle and loaded RSS with the intended single
application before relying on it on a small VPS.

The certificate renewal hook copies a verified matching pair into the overlay
directory and restarts only `edge-infra-nowhere.service`. Existing backup flows
can therefore be interrupted during renewal.

`status` reads Nowhere telemetry as the dedicated service user from its
overlay-owned runtime directory. It does not rely on root seeing a different
user's private temporary-directory records.

## Client boundary

Mihomo currently has no native Nowhere outbound. Run a native Vector separately
on a supported client and point a selected application to Vector's local SOCKS5
listener. Do not add it to the base subscription or fallback group. When a
client is behind F50's transparent Mihomo routing, use the Portal's real IP as
Vector's endpoint and retain the certificate FQDN as SNI. Add only two narrow
F50 `DIRECT` rules matching that exact IP plus TCP `10443` and UDP `10443`;
do not exclude the whole IP from TUN, because that could bypass unrelated
services on the same VPS. Test from a separate network if those scoped rules
cannot be verified; otherwise Vector can recurse through the primary Reality
path.

A full Mihomo configuration reload can interrupt existing connections even
without restarting its process. On a router whose TUN capture is implemented
only by policy routing, an alternative is a separate policy rule for the exact
Portal IPv4, TCP/UDP protocol and destination port, before the TUN lookup. Verify
the router supports port selectors and has no earlier transparent redirect;
keep every other port on its original route. Give this exception its own
rollback and boot/interface-up handling. Do not add a whole-IP bypass or copy
another host's rule priorities without checking the current rules.

The optional `scripts/nowhere-vector.sh` launcher runs one foreground Vector
without changing the system proxy. Its current-user-owned `0600` configuration
is parsed as data and must stay outside Git:

```ini
NOWHERE_BINARY=/absolute/path/to/verified/nowhere
PORTAL_IPV4=203.0.113.10
PORTAL_SNI=relay.example.com
PORTAL_PORT=10443
SHARED_KEY=REPLACE_WITH_THE_PRIVATE_PORTAL_KEY
LOCAL_SOCKS_PORT=1089
```

Use `scripts/nowhere-vector.sh --config /absolute/path/client.env tcp` or
replace `tcp` with `quic`. Point the chosen application's SOCKS5 proxy at
`127.0.0.1:1089`; Ctrl-C stops Vector. The launcher validates NW3 v3.0.1 and
does not print its key or service URL. Download and verify the client archive
against the release asset digest before selecting its binary.

## Rollback

```sh
sudo scripts/nowhere-overlay.sh rollback --yes
```

Rollback stops and removes only this overlay's unit, binary, copied
certificate/configuration, deploy hook, and UFW rules it created. It retains
the dedicated service account and a root-only backup under
`/var/backups/edge-infra-nowhere/`, including the overlay state, unit, CLI,
binary, copied certificate/configuration and a verified checksum archive. It does not touch source certificates,
base services, nginx, subscription files, or firewall tables.
