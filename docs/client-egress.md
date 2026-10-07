# Subscription DNS and IPv6 routing

The full Mihomo subscription includes the common client policy. Refresh the
existing subscription URL to receive it; importing only its proxy nodes does
not import DNS or TUN settings.

## Policy

- Default domain lookups use Cloudflare/Google DoH through `主链路`.
- Proxy-node bootstrap and destinations deliberately routed `DIRECT` use
  separate domestic DoH resolvers. Direct traffic is intentional, not covered
  by a promise that every request leaves through the VPS.
- Top-level `ipv6: true` and an IPv6 TUN address allow native IPv6 traffic to
  enter the tunnel. `dns.ipv6: false` still prefers IPv4 DNS answers; it does
  **not** disable the operating system's IPv6 network.
- TUN captures both UDP and TCP DNS on port 53. Browser encrypted DNS and
  Android Private DNS are separate settings and may bypass this DNS policy.
- The existing Reality/Trojan/HY2 fallback and HY2 PMTU workaround remain.

## Client settings that a subscription cannot guarantee

Desktop clients must have TUN/service permissions enabled. Enable IPv6 in the
client if its local settings override the subscription. Disable conflicting
DNS overrides, or configure them to follow the subscription. Clash Verge owns
some fields, including TUN enablement; a YAML subscription cannot grant OS VPN
permissions or override every local preference.

On Clash Verge Rev 2.5.6, check these once in Settings: TUN on, IPv6 on,
DNS override off. In the TUN dialog use Mixed, auto-route on, strict-route on,
auto-detect-interface on, and DNS hijack `any:53,tcp://any:53`. Preserve any
intentional local route exclusions. Refresh the subscription and reactivate it.

Remove obsolete DNS policies such as `#OpenAI` when refreshing an older
subscription: this subscription exposes only `主链路`. Keep machine-specific
direct rules and route exclusions locally, rather than distributing them to
other devices.

For mobile clients such as Clash Mi, import the full profile, reconnect the
VPN after refresh, and verify the effective DNS and IPv6 behavior. The mobile
VPN implementation may manage TUN independently of the YAML. A successful
download or parser check alone is not proof of leak prevention on that device.

## Acceptance

1. Validate both the downloaded YAML and any merged configuration using the
   actual client core (`mihomo -t -d CLIENT_DATA_DIR -f CANDIDATE`).
2. Verify ordinary HTTP, traffic without an explicit HTTP proxy, and IPv4
   STUN use the intended VPS egress.
3. Test a literal IPv6 destination, including IPv6 STUN. It must use the VPS
   IPv6 for a proxy-routed destination, or be blocked; it must not return the
   device's native public IPv6. An empty AAAA answer is not sufficient.
4. Use DNS resolver echo queries to confirm default lookups no longer use
   the domestic recursive resolver. Compare resolver ownership, not an exact
   match with the web egress IP.
5. Reapply/refresh the profile once more and repeat the checks to catch local
   overrides. Check intentional direct applications still work.

WebRTC may legitimately expose both IPv4 and IPv6 addresses belonging to the
same VPS. This policy does not change the VPS's hosting/proxy classification
or guarantee an IP-score threshold or account access.

## Updating an existing server

Changing the repository template affects future rendering, not an already
published file. Back up the live subscription and any owner manifest/state,
check their current hashes, and stage only the DNS/IPv6/TUN changes. Preserve
credentials, node definitions, fallback order, file ownership and permissions.
Validate the candidate before atomically replacing the published file. Update
the owner's recorded subscription hash in the same maintenance operation;
restore both subscription and state if verification fails. Fetch the existing
HTTPS subscription and compare it with the staged candidate.

The subscription is static nginx content: this change requires no sing-box
restart or nginx configuration change. Keep rollback copies outside the web
root and repository because the subscription contains credentials.

References: [Mihomo DNS](https://wiki.metacubex.one/config/dns/),
[Mihomo TUN](https://wiki.metacubex.one/config/inbound/tun/),
[Clash Verge overrides](https://www.clashverge.dev/guide/extend.html).
