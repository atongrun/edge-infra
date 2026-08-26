# Testing and release gates

## Repository gates

```bash
./scripts/verify.sh
./tests/run.sh
```

GitHub Actions on Ubuntu 24.04 additionally runs Bash syntax checks and ShellCheck.

The test suite currently covers strict config parsing, duplicate/unknown keys,
hopping-range limits, template rendering, monthly traffic-header mapping and
unit permissions, unresolved placeholders, JSON syntax, confirmation gates,
pinned checksums and static rejection of global nftables or curl-pipe-shell
patterns.

## Required real-VPS release test

Before the first stable tag, use a disposable fresh Ubuntu VPS and record:

1. Preflight pass and deliberate conflict failures.
2. Fresh install with DNS and Let's Encrypt issuance.
3. `status`, `verify` and `health` output.
4. Mihomo import, one-click subscription refresh with the 500 GB traffic card,
   and direct testing of HY2, HY2-Hop and Trojan.
5. Simulated HY2 failure, Trojan takeover and HY2 recovery behavior.
6. nftables hopping counter increments.
7. VPS reboot and systemd auto-start.
8. Rollback, port closure, nft table removal and SSH continuity.
9. A second install after rollback.

Until this matrix passes, the code can be public for review but should be labeled pre-release rather than production-ready.
