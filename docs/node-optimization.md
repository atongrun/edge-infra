# Personal node optimization and acceptance

## Rollback after user-reported instability, 2026-10-07

The user reported substantially worse X browsing and node-test reliability
after this change than during the preceding week. Short passing tests did not
establish a long-term stability improvement. Treat the change as a suspected
regression rather than dismissing the report as an unrelated line problem.

Restore the network policy from commit `48794b6`: 60-second health probes and
the previous country-based DIRECT rules, without a catch-all public-UDP proxy
rule. Retain the earlier DNS/IPv6 fixes, the verify exit-status fix and the
separately verified SSH key-only hardening. Domestic STUN may again expose the
native public address under this policy; stability is the immediate priority.

The BBR/FQ trial had already been reverted to CUBIC/pfifo_fast. Restore the
published subscription, its owner state and the installed renderer from the
pre-change backup; refresh and reactivate the Mac profile. Preserve rollback
evidence and compare normal use over time before making further changes.

The measurements below are historical experiment results, not a claim that
the rolled-back policy is currently active or that sustained stability was
proven. Intermittent HY2 failures were also reproduced in an isolated client,
so the precise causal contribution of the changes remains unresolved.

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

The 2026-10-07 short sample used three HTTP 204 requests, two 5 MB downloads
per protocol, and TLS probes to three relevant service hostnames. Download
averages varied approximately as follows (decimal Mbps):

| Protocol | Observed range |
| --- | --- |
| Reality | 11–17 |
| Trojan | 10–17 |
| HY2 | 11–37 |
| HY2 port hopping | 17–50 |

These are small, sequential samples on one access network, not capacity
guarantees or evidence that UDP is always faster. Keep Reality/Trojan first
for independent TCP fallback; HY2 remains available when suitable. Preserve
the established HY2 PMTU compatibility option.

## Original experiment changes (network policy subsequently rolled back)

- Route default public UDP through the proxy before country-based DIRECT
  rules; retain private/local destinations and explicit local exceptions.
- Probe fallback nodes every 30 seconds without changing protocol order.
- On the audited personal VPS, disable SSH password/keyboard-interactive
  authentication and retain root public-key access. This is a separately
  authorized operational change, not a new installer default.

For SSH maintenance, verify a fresh key-only login first, back up effective
settings, validate with `sshd -t`, and schedule a short automatic rollback.
Reload rather than restart sshd, prove a new login works, then cancel the
rollback. Keep recovery instructions with the private server backup.

## Changes deliberately not retained

A reversible trial of the kernel's BBR/FQ settings did not show a sufficiently
clear throughput improvement in this sample. Restore the previous CUBIC and
queue settings; do not install an alternative kernel or change many sysctls
at once. Existing connections and listening sockets may retain older TCP
state, so rigorous comparisons must inspect the tested sockets' algorithms.

Cumulative UDP receive errors alone do not justify increasing buffers. The
counter did not rise during the initial protocol benchmark. No unmeasured
buffer, MTU, offload, or bandwidth-limit changes were made.

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

## Initial short acceptance recorded on 2026-10-07

- Refreshing the original subscription through Clash Verge produced the exact
  published candidate. Effective public-UDP routing precedes the CN bypass.
- All five tested domestic/international IPv4 STUN servers returned the VPS
  egress. IPv6 STUN also returned the VPS IPv6; DNS echoes used Cloudflare.
- An isolated fallback group with an unavailable first candidate selected the
  first healthy candidate and completed an HTTP 204 request with TLS verified.
- Both DNS-01 certificate renewal simulations completed successfully. The
  production certificates were not replaced by the simulation.
- A fresh SSH connection using only the existing public key succeeded after
  password login was disabled; temporary rollback timers were cancelled.
- Repository checks and the regression suite passed. Proxy service PIDs were
  unchanged by the server-side configuration updates.

These checks cover this Mac and the server. Other devices must refresh their
full subscription and recheck effective VPN/TUN settings. Mobile certificate
warnings and destination account eligibility remain unverified by these tests.

## Research references

- [Mihomo rule precedence and network matching](https://wiki.metacubex.one/config/rules/)
- [Mihomo fallback health checks](https://wiki.metacubex.one/config/proxy-groups/)
- [Hysteria performance guidance](https://v2.hysteria.network/docs/advanced/Performance/)
- [Google BBR quick start](https://github.com/google/bbr/blob/master/Documentation/bbr-quick-start.md)
- [DigiCert root compatibility](https://knowledge.digicert.com/general-information/compatibility-of-digicert-trusted-root-certificates)
