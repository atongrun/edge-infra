# Rollback and uninstall

`rollback` and `uninstall` currently share the same V1 behavior:

If the Reality overlay is installed, remove it first so its saved subscription
is restored while the base services and sing-box runtime still exist:

```bash
sudo edge-infra-reality rollback --yes
```

```bash
sudo edge-infra rollback --yes
```

The command:

1. Verifies managed-file hashes and refuses changed files unless `--force` is explicit.
2. Stops/disables only `edge-infra-*` units, including the traffic timer.
3. Deletes only `table inet edge_infra_hy2_hopping`.
4. Deletes only UFW rules carrying an `edge-infra` comment.
5. Removes the edge-infra nginx site and reloads nginx if its remaining config validates.
6. Restores the nginx default symlink only when the transaction removed it.
7. Deletes only the certificate lineage created by this transaction.
8. Removes the dedicated traffic snippet, edge-infra configs, subscription,
   binary, CLI and transaction state.
9. Restores vnStat's prior active/enabled state and preserves the installed APT
   package, `/var/backups/edge-infra/<timestamp>/`, and vnStat's database.

## Why packages remain

nginx, Certbot, nftables, vnStat and their dependencies may become shared after
installation. Automatically removing them during rollback could break
unrelated services or discard traffic history. Package cleanup is therefore a
separate operator decision.

## Changed managed files

If an operator edits a generated subscription or config, normal rollback stops rather than deleting it. Review and copy any desired changes. If the Reality overlay is present, roll it back first; then run:

```bash
sudo edge-infra uninstall --yes --force
```

`--force` bypasses only the managed-file hash gate. It does not broaden filesystem or nftables targets.

## Legacy sing-box binary upgrade

`scripts/upgrade-sing-box.sh` is only for an existing host whose
`/usr/local/bin/sing-box` is a regular file, not the symlink created by a fresh
`edge-infra` install. Preflight is read-only. It does not change credentials,
nftables, nginx, SSH, sysctls, or the Xray sidecar.

Preflight must pass before `upgrade --yes`. The transaction restarts only the
sing-box units that share that binary:

- `sing-box.service` with `/etc/sing-box/config.json`
- `sing-box-trojan.service` with `/etc/sing-box/trojan.json`
- `sing-box-reality.service` with `/etc/sing-box/reality.json`
- `sing-box-extra.service` with `/etc/sing-box/extra.json`, when that unit is
  installed. AnyTLS and TUIC stay in that file. An installed extra unit that is
  not active fails preflight; the upgrade does not skip it or leave it stopped.

These units are checked and then left running. Hopping accepts either the
legacy name or the repository name, and refuses when both are installed:

- `hy2-port-hopping.service` (`inet edge_hy2_port_hopping`) or
  `edge-infra-port-hopping.service` (`inet edge_infra_hy2_hopping`). Both are
  nft redirects to UDP 443. Hop ports have no `ss` listeners; that is the
  redirect, not a missing service.
- `edge-infra-xray-cf.service`, which uses its own Xray binary. The sing-box
  upgrade does not restart it.

`upgrade --yes` arms a 15-minute rollback timer, swaps the binary, and restarts
only the recorded sing-box units. `rollback --yes`, or the timer, restores the
previous binary and restarts those same units. Companion units are checked
still active and are not restarted. `commit --yes` is refused after the timer
has already rolled back. A transaction started by an older copy of this script
has no saved unit list; roll that transaction back instead of committing it
with this copy.

The fresh-install pin in `versions.env` and `UPGRADE_SING_BOX_*` are both
sing-box 1.14.4. `XRAY_*` is Xray-core 26.11.9. Running the Cloudflare overlay
install again does not replace an Xray binary that already has state.
