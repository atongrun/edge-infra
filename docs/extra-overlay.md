# AnyTLS + TUIC v5 overlay

`scripts/extra-overlay.sh` adds two independent inbounds without restarting the
baseline HY2, Trojan or Reality services:

| Node | Transport | Default port | sing-box inbound |
|------|-----------|--------------|------------------|
| `DediOne-AnyTLS` | TCP | 8444 | `anytls`, TLS with the edge certificate |
| `DediOne-TUIC`   | UDP | 8443 | `tuic` v5, BBR, ALPN `h3`, 0-RTT off |

Both run in one extra service, `sing-box-extra.service`
(`/etc/sing-box/extra.json`, mode 0600). Credentials are generated at install
time and only live in that config and in the subscription file. A certbot deploy
hook restarts only `sing-box-extra.service` when the edge certificate renews.

The two client nodes are appended to the END of `主链路`, so the fallback order
stays Reality → Trojan → HY2 → HY2-Hop and the new nodes are only used after all
four existing nodes fail, or when selected manually.

These nodes share the server IP with the existing ones. They help against
protocol fingerprinting; they do not help against a whole-IP TCP block (AnyTLS
would fail together with Reality/Trojan, TUIC would behave like HY2).

## Usage

```bash
cp env/extra.env.example /etc/edge-infra/extra.env && chmod 600 /etc/edge-infra/extra.env
# edit values, then:
scripts/extra-overlay.sh preflight --config /etc/edge-infra/extra.env
# Install the service but only stage the subscription:
EXTRA_SKIP_PUBLISH=1 scripts/extra-overlay.sh install --config /etc/edge-infra/extra.env --yes
# ...run end-to-end proxy tests against both ports...
scripts/extra-overlay.sh publish --yes
edge-infra-extra verify
edge-infra-extra rollback --yes   # restores the pre-install subscription
```

Client requirements: Mihomo with `anytls` support (added in v1.19.3, protocol v2
in v1.19.4; v1.19.5 or newer recommended, validated with v1.19.33) and `tuic` v5.

`reality-overlay.sh` accepts the two extra nodes at the tail of `主链路` only
while `/var/lib/edge-infra-extra/state.env` exists, and refuses a Reality
rollback until the extra overlay is rolled back. The Cloudflare subscription
publisher still expects the four-node chain and refuses to run while these nodes
are published.
