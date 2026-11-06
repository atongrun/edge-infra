#!/usr/bin/env bash
set -Eeuo pipefail
repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

[[ -f templates/xray/cloudflare-xhttp.json ]]
[[ -f templates/nginx/cloudflare-xhttp.conf ]]
[[ -f templates/systemd/edge-infra-xray-cf.service ]]
[[ -f scripts/cloudflare-overlay.sh ]]
[[ -f scripts/cloudflare-subscription.py ]]
[[ -f scripts/publish-cloudflare-subscription.sh ]]
[[ ! -e templates/sing-box/cloudflare-vless-ws.json ]]
[[ ! -e templates/systemd/edge-infra-cloudflared.service ]]
[[ ! -e templates/systemd/edge-infra-cf-ws.service ]]

grep -q '"listen": "127.0.0.1"' templates/xray/cloudflare-xhttp.json
grep -q '"network": "xhttp"' templates/xray/cloudflare-xhttp.json
grep -q '"mode": "packet-up"' templates/xray/cloudflare-xhttp.json
if grep -Eqi 'reality|vision|grpc|websocket|cloudflared' templates/xray/cloudflare-xhttp.json; then
  echo 'Xray template contains a forbidden protocol' >&2
  exit 1
fi
grep -q 'proxy_pass http://127.0.0.1:' templates/nginx/cloudflare-xhttp.conf
grep -q 'proxy_http_version 1.1;' templates/nginx/cloudflare-xhttp.conf
if grep -Eqi 'grpc|cloudflared' templates/nginx/cloudflare-xhttp.conf; then
  echo 'nginx template depends on gRPC or cloudflared' >&2
  exit 1
fi
grep -q 'DynamicUser=true' templates/systemd/edge-infra-xray-cf.service
grep -q 'LoadCredential=xray.json:/etc/edge-infra-cloudflare/xray.json' templates/systemd/edge-infra-xray-cf.service
grep -q 'restart=on-failure\|Restart=on-failure' templates/systemd/edge-infra-xray-cf.service

grep -q 'CF_HOSTNAME=backup.example.com' env/cloudflare.env.example
grep -q 'CF_PREFERRED_IP=' env/cloudflare.env.example
grep -q 'do not commit' env/cloudflare.env.example
if grep -Eq '^[A-Z_]+=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$' env/cloudflare.env.example; then
  echo 'example env contains a UUID value' >&2
  exit 1
fi
grep -q '^XRAY_VERSION=' env/resilience-versions.env.example
grep -q '^XRAY_AMD64_SHA256=[a-f0-9]\{64\}$' env/resilience-versions.env.example
grep -q '^XRAY_ARM64_SHA256=[a-f0-9]\{64\}$' env/resilience-versions.env.example

# shellcheck disable=SC2016
grep -q 'mihomo-linux-$ARCH-v$MIHOMO_VERSION.gz' scripts/publish-cloudflare-subscription.sh
grep -q -- '-t -d' scripts/publish-cloudflare-subscription.sh
grep -q -- '--on-active=60m' scripts/publish-cloudflare-subscription.sh
# shellcheck disable=SC2016
grep -q 'mv -f "$sub_tmp" "$subscription"' scripts/publish-cloudflare-subscription.sh
grep -q 'check_main_chain' scripts/publish-cloudflare-subscription.sh
if grep -Eqi 'cloudflared|cf-ws|network: ws|ws-opts' scripts/cloudflare-overlay.sh scripts/publish-cloudflare-subscription.sh scripts/cloudflare-subscription.py; then
  echo 'old VLESS-WS/cloudflared code remains' >&2
  exit 1
fi
if grep -RIn --exclude-dir=.git --exclude=test-cloudflare-static.sh -E 'CF_SING_BOX|CLOUDFLARED_VERSION|CF_WS_PATH' env scripts templates tests; then
  echo 'old VLESS-WS/cloudflared configuration remains' >&2
  exit 1
fi

echo 'test-cloudflare-static: passed'
