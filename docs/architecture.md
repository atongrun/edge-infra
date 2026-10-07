# Architecture and ownership

## Data plane

The reference topology is:

```text
DediOne-Reality   TCP 9443         VLESS + Reality + Vision, front candidate
DediOne-Trojan    TCP 8443         independent TCP/TLS fallback
DediOne-HY2       UDP 443          primary UDP/QUIC fallback
DediOne-HY2-Hop   UDP 20000-20031  nft redirect -> UDP 443
Subscription      TCP 443          nginx static YAML
Monthly traffic   eth0             vnStat -> Subscription-Userinfo header
ACME              TCP 80           Certbot webroot + HTTPS redirect
```

The published subscription exposes one `主链路` fallback group ordered as
`DediOne-Reality`, `DediOne-Trojan`, `DediOne-HY2`, then `DediOne-HY2-Hop`.
Health selection affects new connections; established connections do not
migrate seamlessly.

HY2 and HY2-Hop remain in the same UDP/QUIC failure domain. Port hopping can work around fixed-port or flow treatment, but the actual heterogeneous fallbacks are the two TCP listeners ahead of them: Reality and Trojan/TLS.

## Failure isolation

- `edge-infra-hy2.service` owns only the primary sing-box config.
- `edge-infra-trojan.service` owns only the Trojan config.
- `edge-infra-port-hopping.service` owns only `table inet edge_infra_hy2_hopping`.
- `sing-box-reality.service` (overlay) owns only `/etc/sing-box/reality.json`; it does not touch HY2, Trojan, port hopping, certificates, or nginx.
- nginx owns TCP 80/443 and the static subscription.
- vnStat persists public-interface RX/TX. A root oneshot atomically updates
  only the edge-infra traffic snippet and gracefully reloads nginx hourly.
- Certbot uses nginx's webroot and a deploy hook that validates before reload/restart.

The sing-box processes never receive `CAP_NET_ADMIN`. The installer does not enable `nftables.service` and never runs `flush ruleset`.

## State and trust boundaries

- Public input: domains, public IPv4, ACME email and optional ports/interface.
- Generated secret state: `/etc/edge-infra/secrets.env` (`0600`).
- Transaction state: `/var/lib/edge-infra/state.env` (`0600`).
- Immutable-file hashes: `/var/lib/edge-infra/manifest.sha256`.
- Preinstall evidence: `/var/backups/edge-infra/<timestamp>/` (`0700`).

The random subscription path is a bearer credential. HTTPS protects it in transit; operators must not publish or commit it.
