# Troubleshooting

## Preflight refused installation

This is expected on a non-fresh host. Read the exact conflict and resolve it manually; do not delete or stop an unknown service merely to make the installer pass.

Useful read-only commands:

```bash
sudo ss -lntup
sudo systemctl --failed
sudo nginx -T
sudo nft list ruleset
sudo ufw status numbered
```

## DNS or ACME failure

Each configured name must have exactly one unique IPv4 answer and it must equal `PUBLIC_IPV4`. TCP 80 must reach nginx from the Internet, and a cloud firewall must allow it. The installer does not create DNS records or cloud security-group rules.

After an install error, inspect the timestamped backup and confirm `edge-infra status` reports no installation before retrying.

## Mihomo subscription parsing

Some Android/older Mihomo builds require an integer `hop-interval`. The template deliberately uses:

```yaml
hop-interval: 20
```

Do not replace it with a range string such as `15-30`.

## Timeout diagnosis

Service `active` and packet arrival alone do not prove a working QUIC path. Check bidirectional packet sizes/timing, buffer error deltas and application logs:

```bash
sudo edge-infra status
sudo edge-infra verify
sudo edge-infra health
sudo journalctl -u edge-infra-hy2 -u edge-infra-trojan --since '10 minutes ago'
sudo nft list table inet edge_infra_hy2_hopping
sudo nstat -az UdpRcvbufErrors UdpSndbufErrors
```

If one carrier fails while another works and the VPS responds promptly, treat the UDP path as the leading suspect. Port hopping may help fixed-port treatment; Trojan is the independent TCP fallback.

## Rollback refused changed files

Copy and review local changes first. Use `--force` only when deleting those changes is intended. The force flag does not permit global nftables or arbitrary filesystem removal.
