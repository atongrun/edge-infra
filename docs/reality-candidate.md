# Reality candidate overlay

This optional overlay adds one isolated `VLESS + Reality + Vision + TCP` candidate to an existing deployment. It does not move nginx, reuse TCP 443, or modify HY2, Trojan, port hopping, certificates, or their systemd units.

## Scope

The overlay owns only:

- `/etc/sing-box/reality.json`;
- `sing-box-reality.service`;
- one comment-scoped UFW TCP rule;
- one `DediOne-Reality` node in the existing subscription;
- `/var/lib/edge-infra-reality` state and a retained backup under `/var/backups/edge-infra-reality`.

Reality is added after the existing `PROXY` entry in both the `Proxies` and `OpenAI` selectors. It is a manual candidate and does not become the default automatically.

## Deploy

Create a root-only config outside Git from `env/reality.env.example`, then run:

```bash
sudo ./scripts/reality-overlay.sh preflight --config /root/reality.env
sudo ./scripts/reality-overlay.sh install --config /root/reality.env --yes
sudo edge-infra-reality verify
```

The target probe must negotiate TLS 1.3 and H2 with a valid certificate before installation. UUID, Reality keys, and short ID are generated only on the VPS.

## Rollback

```bash
sudo edge-infra-reality rollback --yes
```

Rollback stops only the Reality unit, deletes only its UFW rule and config, and restores the exact pre-install subscription hash. Existing subscription edits make rollback fail closed unless `--force` is intentional.

## Client gate

Validate the rendered subscription with the actual Mihomo binary and directly exercise `DediOne-Reality` before beginning dogfood. Test both system proxy and TUN; a successful server listener does not prove Codex or other applications use that route.
