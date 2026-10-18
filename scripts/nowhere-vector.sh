#!/usr/bin/env bash
# Run one foreground Nowhere Vector SOCKS listener without changing system proxy
# settings. The config is parsed as data; it is never sourced by a shell.
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: nowhere-vector.sh --config /absolute/path/client.env [tcp|quic]' >&2
  exit 64
}

config=''
carrier='tcp'
while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || usage
      config=$2
      shift 2
      ;;
    tcp|quic)
      carrier=$1
      shift
      ;;
    *) usage ;;
  esac
done

[[ -n $config ]] || usage
[[ $config = /* ]] || { printf '%s\n' 'config path must be absolute' >&2; exit 64; }

exec python3 - "$config" "$carrier" <<'PY'
import ipaddress
import os
import re
import stat
import subprocess
import sys

config_path, carrier = sys.argv[1:]
required = {
    "NOWHERE_BINARY",
    "PORTAL_IPV4",
    "PORTAL_SNI",
    "PORTAL_PORT",
    "SHARED_KEY",
}
allowed = required | {"LOCAL_SOCKS_PORT"}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(64)


try:
    config_stat = os.stat(config_path)
except OSError:
    fail("cannot read config")

if not stat.S_ISREG(config_stat.st_mode):
    fail("config must be a regular file")
if config_stat.st_uid != os.geteuid():
    fail("config must be owned by the current user")
if stat.S_IMODE(config_stat.st_mode) != 0o600:
    fail("config permissions must be 0600")

values = {}
try:
    lines = open(config_path, encoding="utf-8").read().splitlines()
except OSError:
    fail("cannot read config")

for number, line in enumerate(lines, 1):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    if "=" not in line:
        fail(f"invalid config line {number}")
    key, value = line.split("=", 1)
    if key not in allowed or key in values or value != value.strip():
        fail(f"invalid config field on line {number}")
    values[key] = value

missing = required - values.keys()
if missing:
    fail("config is missing required fields")

binary = values["NOWHERE_BINARY"]
if not os.path.isabs(binary) or not os.path.isfile(binary) or not os.access(binary, os.X_OK):
    fail("NOWHERE_BINARY must be an executable absolute local file")

try:
    portal_ip = ipaddress.IPv4Address(values["PORTAL_IPV4"])
except ipaddress.AddressValueError:
    fail("PORTAL_IPV4 must be an IPv4 address")

sni = values["PORTAL_SNI"]
if len(sni) > 253 or not re.fullmatch(r"(?=.{1,253}\Z)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", sni):
    fail("PORTAL_SNI must be a DNS name")

def parse_port(name, default=None):
    raw = values.get(name, default)
    if raw is None or not re.fullmatch(r"[0-9]{1,5}", raw):
        fail(f"{name} must be a TCP/UDP port")
    port = int(raw)
    if not 1 <= port <= 65535:
        fail(f"{name} must be a TCP/UDP port")
    return port

portal_port = parse_port("PORTAL_PORT")
local_port = parse_port("LOCAL_SOCKS_PORT", "1089")
key = values["SHARED_KEY"]
if not re.fullmatch(r"[0-9a-f]{32}", key):
    fail("SHARED_KEY must be exactly 32 lowercase hexadecimal characters")

try:
    version = subprocess.run(
        [binary, "--version"], check=True, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=5,
    ).stdout
except (OSError, subprocess.SubprocessError):
    fail("cannot verify Nowhere version")
if not re.fullmatch(r"nowhere-v3\.0\.1 [a-z0-9_-]+/[A-Za-z0-9_-]+", version.strip()):
    fail("NOWHERE_BINARY is not Nowhere v3.0.1")

transport = "tcp" if carrier == "tcp" else "udp"
url = f"vector://{key}@{portal_ip}/{transport}:{portal_port}?in=127.0.0.1:{local_port}&sni={sni}&morph=1"

# Do not print the URL, key, portal address, or system-proxy instructions.
print(f"Starting foreground Vector on 127.0.0.1:{local_port} ({carrier}); Ctrl-C stops it.", file=sys.stderr)
os.execv(binary, [binary, url])
PY
