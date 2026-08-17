#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

bash -n scripts/reality-overlay.sh
grep -q 'REALITY_PORT=9443' env/reality.env.example
grep -q 'REALITY_TARGET=dl.google.com' env/reality.env.example
grep -q 'type:"vless"' scripts/reality-overlay.sh
grep -q 'flow:"xtls-rprx-vision"' scripts/reality-overlay.sh
grep -q 'network: tcp' scripts/reality-overlay.sh
grep -q 'client-fingerprint: chrome' scripts/reality-overlay.sh
grep -q 'DediOne-Reality' scripts/reality-overlay.sh
grep -q 'SING_BOX_BIN=/usr/local/bin/sing-box' scripts/reality-overlay.sh
grep -q 'wait_for_listener' scripts/reality-overlay.sh
grep -q 'CapabilityBoundingSet=$' templates/systemd/edge-infra-reality.service

if grep -Eq 'systemctl (restart|reload) (sing-box|sing-box-trojan|nginx)' scripts/reality-overlay.sh; then
  echo 'Reality overlay may mutate a baseline service' >&2
  exit 1
fi

echo 'Reality overlay static checks passed'
