# edge-infra installation guide

This is the authoritative installation guide for a fresh Ubuntu VPS. The goal
is to deploy the reference topology as quickly as possible while keeping the
deployment auditable, isolated, and reversible.

The target topology is:

```text
TCP 9443  VLESS + Reality + Vision       DediOne-Reality (front candidate)
TCP 8443  Trojan/TLS                     DediOne-Trojan (fallback)
UDP 443   Hysteria2                       DediOne-HY2 (fallback)
UDP 20000-20031 -> UDP 443                DediOne-HY2-Hop (fallback)
TCP 443   nginx HTTPS subscription
TCP 80    nginx ACME challenge/redirect
```

The published Mihomo group must be ordered exactly as:

```text
主链路: DediOne-Reality -> DediOne-Trojan -> DediOne-HY2 -> DediOne-HY2-Hop
```

Do not substitute a different order merely because a transport is faster in a
local test. Reality and Trojan are intentionally ahead of the two HY2 paths to
provide heterogeneous TCP fallbacks.

## 1. Agent operating rules

The agent is operating a production-like VPS. Before mutating anything:

1. Read this entire guide and the linked repository documentation.
2. Inspect the current host, but do not remove or overwrite unrelated services.
3. Ask the operator for missing public inputs; never ask for or invent generated
   proxy passwords or Reality private keys.
4. Run the repository preflight and stop on any failure.
5. Use a reviewed tag or commit, not an unreviewed moving checkout when a stable
   release is available.
6. Do not use `curl | sh`, `curl | sudo sh`, or equivalent remote-root execution.
7. Do not claim completion until local verification and an external client test
   both pass.

If the host is not a fresh supported host, stop and report the conflict instead
of attempting an in-place migration.

## 2. Supported host and required inputs

The supported host is:

- Ubuntu 22.04 or 24.04;
- amd64 or arm64;
- root or sudo access, normally through one active SSH session;
- one unambiguous default IPv4 interface;
- TCP 80, 443 and 8443 unused;
- UDP 443 and UDP 20000-20031 unused;
- two DNS A records, each resolving only to the VPS public IPv4.

Ask the operator for:

- `EDGE_DOMAIN`: proxy FQDN and certificate name;
- `SUB_DOMAIN`: HTTPS subscription FQDN;
- `PUBLIC_IPV4`: public VPS IPv4, unless safely detected and confirmed;
- `ACME_EMAIL`: Let's Encrypt email;
- `REALITY_TARGET`: Reality handshake target, default `dl.google.com`;
- `REALITY_SERVER_NAME`: Reality SNI, normally the target, default
  `dl.google.com`.

The default ports are `9443` for Reality, `8443` for Trojan, `443/udp` for
HY2, and `20000-20031/udp` for hopping. Change them only when the operator has
a concrete reason and understands that this no longer exactly matches the
live topology.

## 3. Fetch and inspect the repository

On the new VPS:

```bash
git clone https://github.com/atongrun/edge-infra.git
cd edge-infra
git checkout v0.1.0
```

If the operator explicitly selected a branch or commit, record it in the
handoff. Do not silently switch versions during installation.

Run the public repository checks before installation:

```bash
bash -n install.sh bin/edge-infra scripts/reality-overlay.sh
./scripts/verify.sh
./tests/run.sh
```

These checks are repository checks only; they do not replace host preflight.

## 4. Fast path: interactive orchestrator

For a human-supervised fresh deployment, run:

```bash
sudo ./install.sh
```

Review every prompted value and the final confirmation. The script:

1. writes `/root/edge-infra-install.env` with mode `0600`;
2. runs base preflight and base installation;
3. discovers the generated subscription path from
   `/var/lib/edge-infra/state.env`;
4. writes `/root/edge-infra-reality.env` with mode `0600`;
5. runs Reality preflight and the overlay installation;
6. prints the subscription URL only after both phases return successfully.

If the base phase succeeds but the overlay phase fails, do not report success.
Preserve the diagnostic output, confirm whether the base service is intended
to remain available, and either fix the reported issue and retry the overlay or
roll back the base transaction deliberately:

```bash
sudo ./scripts/reality-overlay.sh preflight --config /root/edge-infra-reality.env
sudo ./scripts/reality-overlay.sh install --config /root/edge-infra-reality.env --yes
# If abandoning the deployment:
sudo edge-infra rollback --yes
```

The one-key script is an orchestrator; each underlying phase still performs
its own fail-closed preflight and verification.

## 5. Agent-controlled non-interactive path

When the agent needs explicit control, create the public base config outside
the repository. Start from the example, then edit it with the operator's
values:

```bash
sudo install -m 0600 env/install.env.example /root/edge-infra.env
sudoedit /root/edge-infra.env
```

At minimum it must contain:

```ini
EDGE_DOMAIN=edge.example.com
SUB_DOMAIN=sub.example.com
PUBLIC_IPV4=203.0.113.10
ACME_EMAIL=admin@example.com
```

Run and inspect preflight:

```bash
sudo ./bin/edge-infra preflight --config /root/edge-infra.env
```

Only after preflight passes and the operator has approved the output:

```bash
sudo ./bin/edge-infra install --config /root/edge-infra.env --yes
```

The base installer generates HY2/Trojan passwords and the random subscription
bearer path on the VPS. It installs the pinned sing-box release only after
verifying its SHA256, renders isolated systemd units, obtains the certificate,
and verifies the base deployment.

Create the Reality config after the base installation, using the actual
subscription path from the base state:

```bash
sudo install -m 0600 /dev/null /root/edge-infra-reality.env
sudoedit /root/edge-infra-reality.env
```

Example:

```ini
REALITY_SERVER=edge.example.com
REALITY_PORT=9443
REALITY_TARGET=dl.google.com
REALITY_SERVER_NAME=dl.google.com
SUBSCRIPTION_FILE=/var/www/edge-infra-subscription/<generated-token>.yaml
```

Then run:

```bash
sudo ./scripts/reality-overlay.sh preflight --config /root/edge-infra-reality.env
sudo ./scripts/reality-overlay.sh install --config /root/edge-infra-reality.env --yes
```

The overlay generates the VLESS UUID, Reality keypair, and short ID locally on
the VPS. It does not restart or rewrite the baseline HY2, Trojan, nginx, or
port-hopping services.

## 6. Verification gate

Do not hand the deployment to the operator until all applicable checks pass:

```bash
sudo edge-infra status
sudo edge-infra verify
sudo edge-infra-reality verify
sudo edge-infra health
```

Confirm the following explicitly:

- `edge-infra-hy2.service`, `edge-infra-trojan.service`,
  `edge-infra-port-hopping.service`, `nginx.service`, and
  `sing-box-reality.service` are enabled and active;
- TCP 9443, TCP 8443, TCP 443, TCP 80, UDP 443, and the hopping range have the
  expected listeners;
- the subscription contains exactly one `DediOne-Reality` node;
- `主链路` has the exact Reality → Trojan → HY2 → HY2-Hop order;
- no legacy nested `PROXY`, `Proxies`, or `OpenAI` group remains in the
  simplified subscription;
- the local HTTPS subscription request succeeds;
- the Reality target probe negotiated TLS 1.3 and h2;
- UFW behavior is understood: an already-active UFW gets scoped rules, while an
  inactive or absent UFW is left unchanged.

The subscription URL is a bearer credential. Display it only to the operator,
do not commit it, and do not paste it into tickets or public logs.

## 7. External client smoke test

A local service check is not enough. On a trusted client:

1. import the printed HTTPS subscription URL into Mihomo/Clash Verge;
2. confirm `DediOne-Reality` can establish a connection;
3. test the `主链路` group and confirm the fallback group is usable;
4. test an ordinary HTTPS destination and the operator's required external
   services;
5. if relevant, test both system proxy and TUN mode;
6. record only high-level pass/fail results, never generated credentials.

To validate failover, deliberately stop only a baseline service during a
controlled window, observe fallback selection, and restore it. Do not confuse
HY2 and HY2-Hop with independent failure domains: both are UDP/QUIC paths.

## 8. Handoff and rollback

The handoff should contain:

- the reviewed commit or release identifier;
- the two configured domain names and whether DNS was verified;
- verification commands and pass/fail result;
- external smoke-test result;
- backup directory paths;
- any unresolved warning or operator action.

Do not put passwords, private keys, the subscription bearer path, or private
URLs in the handoff or Git repository.

To remove only the Reality overlay:

```bash
sudo edge-infra-reality rollback --yes
```

To remove the complete base deployment:

```bash
sudo edge-infra rollback --yes
```

Rollback fails closed if managed files or the subscription were changed after
installation. Inspect the diff and use `--force` only when intentional. Keep
the timestamped backup for audit and diagnosis.

## 9. Failure reporting

If any step fails, report:

1. the exact command;
2. the first meaningful error;
3. whether base installation completed;
4. the active services and relevant listener state;
5. the backup/state paths;
6. the safest retry or rollback command.

Never summarize a partially installed host as "deployed".
