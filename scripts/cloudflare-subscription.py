#!/usr/bin/env python3
"""Build an unpublished Mihomo candidate for the Cloudflare XHTTP node.

The candidate must be validated with the target Mihomo binary and published
atomically by publish-cloudflare-subscription.sh.
"""
import argparse
import ipaddress
import os
import re
import stat
import sys
import uuid

NODE = "DediOne-Cloudflare"
BASE = ["DediOne-Reality", "DediOne-Trojan", "DediOne-HY2", "DediOne-HY2-Hop"]
HOSTNAME_RE = re.compile(
    r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}"
)


def build(source, hostname, path, client_id, preferred_ip=None):
    if not HOSTNAME_RE.fullmatch(hostname):
        raise ValueError("invalid hostname")
    if not re.fullmatch(r"/[A-Za-z0-9/_-]{1,128}", path) or "//" in path:
        raise ValueError("invalid XHTTP path")
    if str(uuid.UUID(client_id)) != client_id:
        raise ValueError("UUID must be canonical lowercase")
    if preferred_ip:
        address = ipaddress.ip_address(preferred_ip)
        server = str(address)
    else:
        server = hostname

    lines = source.splitlines(keepends=True)
    if not source.endswith("\n") or lines.count("proxies:\n") != 1 or lines.count("proxy-groups:\n") != 1:
        raise ValueError("unsupported subscription layout")
    if any(re.match(r"^- name: " + re.escape(NODE) + r"\s*$", x) for x in lines):
        raise ValueError("Cloudflare node already exists")
    groups = [i for i, line in enumerate(lines) if line == "- name: 主链路\n"]
    if len(groups) != 1:
        raise ValueError("expected exactly one main chain")
    start = groups[0]
    end = next(
        (i for i in range(start + 1, len(lines))
         if re.match(r"^(?:- name: |[A-Za-z0-9_-]+:)", lines[i])),
        len(lines),
    )
    if lines[start:end].count("  type: fallback\n") != 1 or lines[start:end].count("  proxies:\n") != 1:
        raise ValueError("main chain must be a fallback with an explicit proxy list")
    members = [x.strip()[2:] for x in lines[start:end] if x.startswith("  - ")]
    if members != BASE:
        raise ValueError("unexpected main-chain order")
    proxy_section = lines[:lines.index("proxy-groups:\n")]
    for name in BASE:
        if sum(x == f"- name: {name}\n" for x in proxy_section) != 1:
            raise ValueError("missing or duplicate baseline node")
    insert = next(i for i in range(start, end) if lines[i] == f"  - {BASE[-1]}\n") + 1
    lines.insert(insert, f"  - {NODE}\n")
    node = (
        f"- name: {NODE}\n"
        "  type: vless\n"
        f"  server: {server}\n"
        "  port: 443\n"
        f"  uuid: {client_id}\n"
        "  udp: false\n"
        "  network: xhttp\n"
        "  tls: true\n"
        f"  servername: {hostname}\n"
        "  alpn: [h2]\n"
        "  xhttp-opts:\n"
        f"    path: {path}\n"
        "    mode: packet-up\n"
        f"    host: {hostname}\n"
        "    headers:\n"
        f"      Host: {hostname}\n"
    )
    lines.insert(lines.index("proxy-groups:\n"), node)
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True, help="new candidate file; existing files are never overwritten")
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--uuid-file", required=True, help="private file containing the client UUID")
    parser.add_argument(
        "--preferred-ip", "--server-ip",
        default=os.environ.get("CF_PREFERRED_IP", ""),
        help="optional Cloudflare anycast IP used as server",
    )
    args = parser.parse_args()
    for filename in (args.source, args.uuid_file):
        if not stat.S_ISREG(os.lstat(filename).st_mode):
            raise ValueError("inputs must be regular files, not symlinks")
    if os.stat(args.uuid_file).st_mode & 0o077:
        raise ValueError("UUID file must not be accessible by group or others")
    with open(args.source, encoding="utf-8") as source_file:
        source = source_file.read()
    with open(args.uuid_file, encoding="ascii") as uuid_file:
        client_id = uuid_file.read().strip()
    candidate = build(source, args.hostname, args.path, client_id, args.preferred_ip)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as output_file:
        output_file.write(candidate)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f"candidate generation failed: {exc}", file=sys.stderr)
        sys.exit(1)
