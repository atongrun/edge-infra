# Architecture and ownership

## Data plane

```text
Edge-HY2       UDP 443          primary
Edge-HY2-Hop   UDP range        nft redirect -> UDP 443
Edge-Trojan    TCP 8443         independent TCP/TLS fallback
Subscription   TCP 443          nginx static YAML
ACME           TCP 80           Certbot webroot + HTTPS redirect
```

Mihomo uses a `fallback` group ordered as `Edge-HY2`, `Edge-HY2-Hop`, then `Edge-Trojan`. Health selection affects new connections; established connections do not migrate seamlessly.

HY2 and HY2-Hop remain in the same UDP/QUIC failure domain. Port hopping can work around fixed-port or flow treatment, but Trojan/TLS is the actual heterogeneous fallback.

## Failure isolation

- `edge-infra-hy2.service` owns only the primary sing-box config.
- `edge-infra-trojan.service` owns only the Trojan config.
- `edge-infra-port-hopping.service` owns only `table inet edge_infra_hy2_hopping`.
- nginx owns TCP 80/443 and the static subscription.
- Certbot uses nginx's webroot and a deploy hook that validates before reload/restart.

The sing-box processes never receive `CAP_NET_ADMIN`. The installer does not enable `nftables.service` and never runs `flush ruleset`.

## State and trust boundaries

- Public input: domains, public IPv4, ACME email and optional ports/interface.
- Generated secret state: `/etc/edge-infra/secrets.env` (`0600`).
- Transaction state: `/var/lib/edge-infra/state.env` (`0600`).
- Immutable-file hashes: `/var/lib/edge-infra/manifest.sha256`.
- Preinstall evidence: `/var/backups/edge-infra/<timestamp>/` (`0700`).

The random subscription path is a bearer credential. HTTPS protects it in transit; operators must not publish or commit it.
