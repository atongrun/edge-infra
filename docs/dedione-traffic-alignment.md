# Audited DediOne 500 GiB instance: coordinated traffic release

This profile aligns only the audited 2026-10-17 instance panel: 379.89 / 500 GB,
75.98%, IN 190.13, OUT 189.76. Counters support binary GiB despite the GB label.
It is not an official provider-wide billing policy. Other hosts and decimal
packages must keep their existing exact-byte quota and billing direction.

`env/dedione-500gib-traffic.env.example` is an allowlisted override reference,
not a replacement for a complete live configuration. Apply only
`TOTAL_BYTES=536870912000` and retain `BILLING_MODE=both` on the audited instance.
Do not source this profile on arbitrary hosts or change global installer defaults.

## Release procedure (requires deployment approval; not run by this PR)

1. Review the coordinated Dash PR and this collector PR; record the reviewed
   commits. On the existing host, preserve root-only backups of
   `/etc/edge-infra/traffic.env`, `/usr/local/sbin/edge-infra-traffic`, and
   `/etc/nginx/snippets/edge-infra-traffic/subscription-userinfo.conf` with their
   modes/owners. Keep all subscription paths/credentials out of logs.
2. Recheck the approved host alias, the only selected interface `eth0`, the
   active hourly timer and existing `BILLING_MODE=both`. Inspect only allowlisted
   keys, not the full runtime env. Stop if the live collector differs from the
   audited collector except for reviewed changes. In particular preserve its
   bounded validation, failure propagation and billing-mode behavior; these
   live behaviors are included in this patch so they are not lost.
3. Install only the reviewed `scripts/traffic-header.sh` over the existing
   executable, preserving executable permissions/ownership. In the existing
   traffic env, atomically replace the single `TOTAL_BYTES=500000000000` line
   with `TOTAL_BYTES=536870912000`, preserving all other fields, owner and mode.
   Do not install the example as a complete file and do not run install.sh.
4. Use the existing collector's `render` action first: confirm unchanged RX/TX
   counters, total 536870912000 and one `X-Traffic-Sampled-At` header taken from
   vnStat's updated.timestamp. Then invoke its existing `update` action once.
   It tests nginx and reloads nginx only when installing the new snippet,
   retaining its existing rollback behavior. Do not reset vnStat, restart proxy
   services or alter interfaces, monthly rotation, credentials or network policy.
5. Publish the coordinated Dash revision in the same window. Verify `verify`
   succeeds, and use the actual protected subscription endpoint to inspect only
   the traffic and sample headers (never log its bearer path or response body).
   Confirm the API and normal Infra page show 500 GiB, server IN/OUT, matching
   raw bytes and a separate sample time. Verify the hourly timer remains active.

The sample timestamp and byte counters are read from the same vnStat JSON
snapshot. It is neither the script run time nor the HTTP response time. Failure
to read vnStat or its timestamp emits no replacement header. Missing sample
headers in older deployments are shown as unknown by the coordinated Dash PR.
The existing hourly schedule stays unchanged.

Subscription clients see `total` increase from 500000000000 to 536870912000
bytes (+7.374%); upload/download byte counters retain their meanings and are not
reset or rescaled. Clients can refresh their subscription to obtain the corrected
quota. Provider/guest counters may differ slightly and their update times differ.
Provider reset date/timezone and backend lag have not been independently verified.

## Rollback

Restore the three protected backups together and the previous Dash revision.
Test nginx configuration before its reload; use the existing reload mechanism.
Do not restore or reset the vnStat database. Recheck the allowlisted quota,
counters, timer and endpoint headers. Treat the quota/display/sampling changes
as one release; avoid leaving an old quota with a new GiB display indefinitely.
