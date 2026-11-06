#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/edge-cf-overlay.XXXXXX)
# shellcheck source=../scripts/cloudflare-overlay.sh
source "$root/scripts/cloudflare-overlay.sh"
trap 'rm -rf -- "$tmp"' EXIT
CONF=$tmp/config
printf 'CF_HOSTNAME=example.com\nCF_HOSTNAME=duplicate.example.com\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted duplicate key' >&2; exit 1; fi
grep -q 'duplicate config key' "$tmp/out"
printf 'UNKNOWN_KEY=value\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted unknown key' >&2; exit 1; fi
grep -q 'unknown config key' "$tmp/out"
printf 'CF_HOSTNAME=invalid\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted invalid hostname' >&2; exit 1; fi
grep -q 'invalid hostname' "$tmp/out"
# Simulate a service-start failure without touching real services or owned paths.
if (
  # shellcheck source=../scripts/cloudflare-overlay.sh
  source "$root/scripts/cloudflare-overlay.sh"
  ROOT=$root; ETC=$tmp/etc; LIB=$tmp/lib; STATE=$tmp/state; UNIT=$tmp/units
  mkdir -p "$UNIT"
  preflight() { ARCH=amd64; CF_HOSTNAME=example.com; CF_ORIGIN_PORT=18080; CF_WS_PATH=/test; CF_TUNNEL_ID=00000000-0000-4000-8000-000000000000; CF_CREDENTIALS_FILE=$tmp/cred; }
  sha256sum() { cat >/dev/null; }
  # shellcheck disable=SC2016
  tar() { local dir=''; while (($#)); do if [[ $1 == -C ]]; then dir=$2; break; fi; shift; done; mkdir -p "$dir/sing-box-1.13.18-linux-amd64"; printf '#!/bin/sh\n[ "$1" = generate ] && echo 12345678-1234-4234-8234-123456789abc\nexit 0\n' > "$dir/sing-box-1.13.18-linux-amd64/sing-box"; }
  jq() { echo '{}'; }
  systemd-run() { :; }
  systemctl() { [[ $1 != enable ]]; }
  printf '#!/bin/sh\nexit 0\n' > "$tmp/fake-cloudflared"
  curl() { local out=''; while (($#)); do if [[ $1 == -o ]]; then out=$2; break; fi; shift; done; if [[ $out == */cloudflared ]]; then cp "$tmp/fake-cloudflared" "$out"; else : > "$out"; fi; }
  : > "$tmp/cred"
  YES=1
  install_overlay
) >"$tmp/failure-log" 2>&1; then echo 'accepted failed service start' >&2; exit 1; fi
[[ ! -e $tmp/etc && ! -e $tmp/lib && ! -e $tmp/state ]]
[[ ! -e $tmp/units/edge-infra-cf-ws.service && ! -e $tmp/units/edge-infra-cloudflared.service ]]
echo 'test-cloudflare-overlay: passed'
