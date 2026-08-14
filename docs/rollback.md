# Rollback and uninstall

`rollback` and `uninstall` currently share the same V1 behavior:

```bash
sudo edge-infra rollback --yes
```

The command:

1. Verifies managed-file hashes and refuses changed files unless `--force` is explicit.
2. Stops/disables only `edge-infra-*` units.
3. Deletes only `table inet edge_infra_hy2_hopping`.
4. Deletes only UFW rules carrying an `edge-infra` comment.
5. Removes the edge-infra nginx site and reloads nginx if its remaining config validates.
6. Restores the nginx default symlink only when the transaction removed it.
7. Deletes only the certificate lineage created by this transaction.
8. Removes edge-infra configs, subscription, binary, CLI and transaction state.
9. Preserves `/var/backups/edge-infra/<timestamp>/` and installed APT packages.

## Why packages remain

nginx, Certbot, nftables and their dependencies may become shared after installation. Automatically removing them during rollback could break unrelated services. Package cleanup is therefore a separate operator decision.

## Changed managed files

If an operator edits a generated subscription or config, normal rollback stops rather than deleting it. Review and copy any desired changes, then run:

```bash
sudo edge-infra uninstall --yes --force
```

`--force` bypasses only the managed-file hash gate. It does not broaden filesystem or nftables targets.
