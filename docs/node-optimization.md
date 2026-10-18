# Node optimization and acceptance

Use the [maintenance checklist](hardening-checklist.md) for host upkeep.

## Measured approach

Use an isolated loopback-only client with the same node definitions when
comparing protocols. Do not switch the user's active group for a speed test.
Bind its outbound interface to the physical interface and resolve the node
endpoint independently so the test does not accidentally nest through the
active TUN. Keep credentials and raw live configurations outside this repo.

Measure small HTTPS response times separately from download throughput.
Repeat warm/cold connections and limit traffic. A successful TLS handshake
and an HTTP 403 prove different things: certificate validation can succeed
while the application rejects a non-browser request. Neither is an account
eligibility test.

Keep Reality/Trojan first for independent TCP fallback. Preserve
`disable-mtu-discovery: true` in HY2 nodes. Increase UDP buffers only when
error counters grow during the affected workload.

## Certificate errors on mobile

An intermittent iOS app certificate warning is not an IP-reputation score.
Node transport certificates and the destination application's HTTPS
certificates are separate trust layers. Do not disable certificate validation
or install an unknown root certificate to hide an error.

Check certificate expiry and the renewal mechanism. Test renewal with
`certbot renew --dry-run --non-interactive --no-random-sleep-on-renew`; do not
add `--run-deploy-hooks` unless a service reload is explicitly intended.
Successful node-side tests do not establish that the iOS app issue is fixed.
If it recurs on both Wi-Fi and cellular, capture the app/iOS/client versions,
exact time, selected node, target hostname from the client log, and whether
Safari works at the same time. Review HTTPS inspection or managed-device
profiles with their owner rather than deleting them blindly.

## Research references

- [Mihomo rule precedence and network matching](https://wiki.metacubex.one/config/rules/)
- [Mihomo fallback health checks](https://wiki.metacubex.one/config/proxy-groups/)
- [Hysteria performance guidance](https://v2.hysteria.network/docs/advanced/Performance/)
- [Google BBR quick start](https://github.com/google/bbr/blob/master/Documentation/bbr-quick-start.md)
- [DigiCert root compatibility](https://knowledge.digicert.com/general-information/compatibility-of-digicert-trusted-root-certificates)
