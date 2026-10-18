# Host maintenance checklist

This checklist applies to an existing host. Verify the live layout first:
legacy `sing-box*` units and a repository-installed `edge-infra-*` stack have
different owners. Do not run the fresh installer over a legacy deployment.

## Before mutation

- Confirm a fresh SSH key login, OS identity, disk/memory headroom and service
  topology. Preserve the current kernel as a boot fallback.
- Archive configs, package inventory, subscription and owner state under a
  root-only directory outside the webroot and Git. A config archive is not a
  full VPS image and cannot automatically roll back a package upgrade.
- Run the Reality verifier where present. Validate a subscription candidate
  with the actual client core and retain the current routing/PMTU policy.

## Subscription access

Use a random 48-hex-character filename as a bearer credential, HTTPS, an exact
nginx location and a default 404. Use `root:www-data`/0640 for the YAML and
0750 for its webroot. Disable access logging for the bearer endpoint; keep
backups outside the served directory. A predictable path makes unauthorized
retrieval possible, but does not by itself prove past access or leakage.

For an existing path change: stage the new file and nginx location, update the
Reality owner's `SUBSCRIPTION_FILE`, mode/UID/GID and hash, validate nginx,
reload, compare the HTTPS response, and update trusted clients. The former
path must return 404 and its file must be moved outside the webroot. Keep the
new URL outside Git and ordinary logs. Old clients need the new URL even
though cached nodes can keep connecting. Rotating a URL alone does not revoke
node credentials already obtained by another party; confirmed exposure calls
for HY2/Trojan/VLESS credential rotation as a separate coordinated operation.

## Security patches and disk

`unattended-upgrades.service` being active is insufficient. Check the effective
APT settings: `APT::Periodic::Update-Package-Lists` and
`APT::Periodic::Unattended-Upgrade` must be `1` for daily updates. Keep allowed
origins restricted to the normal Ubuntu/security sources and automatic reboot
disabled. Validate using `unattended-upgrade --dry-run --debug`.

Refresh official package indexes, inspect `apt-get -s upgrade --with-new-pkgs`
for removals and conflicts, then upgrade in a maintenance window. Preserve
local configuration with deliberate conffile handling. A small RAM host can
use temporary swap during dpkg; remove that temporary file after reboot and
successful verification. Do not remove the previous kernel during this window.

Use a journald drop-in with `SystemMaxUse=200M`, `SystemKeepFree=1G` and
`RuntimeMaxUse=50M`. Archive important history outside the journal before
rotating/vacuuming. Vacuum limits archived files; active journal files mean
total usage need not be exactly 200MB. Recheck disk after upgrade/cache cleanup.

## Traffic accounting

For a new deployment set these in the public install config:

```ini
TRAFFIC_TOTAL_BYTES=500000000000
TRAFFIC_BILLING_MODE=both
```

500 GB decimal is 500000000000 bytes; 500 GiB is 536870912000 bytes. Confirm
quota units, billing direction and cycle start with the provider. Until that
is known, 500 GB decimal with both directions is a conservative display, not
proof of the provider's remaining allowance. The current collector uses the
server's calendar month; it does not implement an arbitrary billing date.
`tx` means VPS outbound only, `rx` inbound only, `both` their sum.

Existing hosts configure `TOTAL_BYTES` and `BILLING_MODE` in the root-only
`/etc/edge-infra/traffic.env`; update/verify using `edge-infra-traffic`.
The nginx header refreshes hourly. Set a trusted client's subscription refresh
to 120 minutes to reduce cached-card staleness. Some clients label binary
GiB as GB, so a decimal 500 GB quota may appear as about 466 GB on the card.

Do not silently replace a user's MATCH route to save quota. Changing streaming
or bulk downloads to another provider/DIRECT is a separate routing decision.
A linear usage forecast is only a warning; it depends on future use, billing
direction, quota units and the actual reset date.

## After reboot

Verify new kernel, SSH, every proxy unit, nginx, hopping rules, traffic timer,
certificate validity and subscription hash/headers. Run Reality verification
and externally test each of Reality, Trojan, HY2 and HY2-Hop with an isolated
Mihomo client. Test the active client too. Keep environment-specific results
and recovery locations in private local records outside tracked public docs.
Publish only reusable methods and sanitized examples; omitting credentials
alone does not make a personal deployment report suitable for publication.
Do not publish a new release until the fresh-host lifecycle matrix passes.

References: [Ubuntu automatic updates](https://ubuntu.com/server/docs/how-to/software/automatic-updates/),
[systemd journald.conf](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html).
