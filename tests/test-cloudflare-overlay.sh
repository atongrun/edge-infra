#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/edge-cf-overlay.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=../scripts/cloudflare-overlay.sh
source "$root/scripts/cloudflare-overlay.sh"

CONF=$tmp/config
printf 'CF_HOSTNAME=example.com\nCF_HOSTNAME=duplicate.example.com\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted duplicate key' >&2; exit 1; fi
grep -q 'duplicate config key' "$tmp/out"
printf 'UNKNOWN_KEY=value\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted unknown key' >&2; exit 1; fi
grep -q 'unknown config key' "$tmp/out"
printf 'CF_HOSTNAME=invalid\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted invalid hostname' >&2; exit 1; fi
grep -q 'valid FQDN' "$tmp/out"
printf 'CF_HOSTNAME=backup.example.com\nCF_XRAY_PORT=443\nCF_XHTTP_PATH=/x\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted invalid loopback port' >&2; exit 1; fi
grep -q 'CF_XRAY_PORT' "$tmp/out"
printf 'CF_HOSTNAME=backup.example.com\nCF_XRAY_PORT=18080\nCF_XHTTP_PATH=/x\nCF_PREFERRED_IP=bad\n' > "$CONF"
if (load_config) >"$tmp/out" 2>&1; then echo 'accepted invalid preferred IP' >&2; exit 1; fi
grep -q 'CF_PREFERRED_IP' "$tmp/out"

# Direct hostname guard: a CF hostname may not equal or duplicate an existing
# direct server_name.
mkdir -p "$tmp/nginx/sites-available" "$tmp/nginx/sites-enabled"
NGINX_CONF_ROOT=$tmp/nginx
NGINX_SITE=$tmp/nginx/sites-available/edge-infra-cloudflare.conf
NGINX_LINK=$tmp/nginx/sites-enabled/edge-infra-cloudflare.conf
BASE_STATE=$tmp/base.env
REALITY_STATE=$tmp/reality.env
printf 'EDGE_DOMAIN=edge.example.com\nSUB_DOMAIN=sub.example.com\n' > "$BASE_STATE"
printf 'REALITY_SERVER=edge.example.com\n' > "$REALITY_STATE"
CF_HOSTNAME=edge.example.com
if (check_direct_hostname_guard) >"$tmp/out" 2>&1; then echo 'accepted an existing direct hostname' >&2; exit 1; fi
grep -q 'must be a NEW hostname' "$tmp/out"
CF_HOSTNAME=backup.example.com
printf 'server { server_name backup.example.com; }\n' > "$tmp/nginx/sites-available/direct.conf"
if (check_direct_hostname_guard) >"$tmp/out" 2>&1; then echo 'accepted a duplicate nginx server_name' >&2; exit 1; fi
grep -q 'already appears' "$tmp/out"
rm -f "$tmp/nginx/sites-available/direct.conf"
(check_direct_hostname_guard)

# Rendering keeps XHTTP on loopback and never adds direct hostnames.
CF_XRAY_PORT=18080
CF_XHTTP_PATH=/secret-path
CF_UUID=12345678-1234-4234-8234-123456789abc
render_xray_config > "$tmp/xray.json"
jq -e '.inbounds[0].listen == "127.0.0.1" and .inbounds[0].port == 18080 and
       .inbounds[0].streamSettings.network == "xhttp" and
       .inbounds[0].streamSettings.xhttpSettings.mode == "packet-up" and
       .inbounds[0].streamSettings.xhttpSettings.path == "/secret-path"' "$tmp/xray.json" >/dev/null
CF_CERT_NAME=backup.example.com
CF_PREFERRED_IP=''
render_nginx_site > "$tmp/site.conf"
grep -q 'server_name backup.example.com;' "$tmp/site.conf"
grep -q 'proxy_pass http://127.0.0.1:18080;' "$tmp/site.conf"
grep -q 'location ^~ /secret-path' "$tmp/site.conf"
if grep -Eq 'grpc|edge\.example\.com|sub\.example\.com' "$tmp/site.conf"; then
  echo 'nginx site contains a forbidden direct name or gRPC setting' >&2
  exit 1
fi

# Simulate a service-start failure after owned files were written. The install
# transaction must remove everything it created.
if (
  CF_ETC_OVERRIDE=$tmp/install-etc
  CF_LIB_OVERRIDE=$tmp/install-lib
  CF_STATE_DIR_OVERRIDE=$tmp/install-state
  CF_UNIT_DIR_OVERRIDE=$tmp/install-units
  CF_NGINX_SITE_OVERRIDE=$tmp/install-nginx/cloudflare.conf
  CF_NGINX_LINK_OVERRIDE=$tmp/install-nginx-enabled/cloudflare.conf
  export CF_ETC_OVERRIDE CF_LIB_OVERRIDE CF_STATE_DIR_OVERRIDE CF_UNIT_DIR_OVERRIDE
  export CF_NGINX_SITE_OVERRIDE CF_NGINX_LINK_OVERRIDE
  # shellcheck source=../scripts/cloudflare-overlay.sh
  source "$root/scripts/cloudflare-overlay.sh"
  ETC=$CF_ETC_OVERRIDE; LIB=$CF_LIB_OVERRIDE; STATE_DIR=$CF_STATE_DIR_OVERRIDE
  STATE_FILE=$STATE_DIR/state.env
  UNIT_DIR=$CF_UNIT_DIR_OVERRIDE; UNIT_PATH=$UNIT_DIR/$UNIT_NAME
  NGINX_SITE=$CF_NGINX_SITE_OVERRIDE; NGINX_LINK=$CF_NGINX_LINK_OVERRIDE
  mkdir -p "$UNIT_DIR"
  load_versions() { XRAY_VERSION=1.0.0; XRAY_SHA=$(printf 'a%.0s' {1..64}); ARCH=amd64; }
  download_xray() { :; }
  # shellcheck disable=SC2016
  extract_xray() { printf '#!/bin/sh\n[ "$1" = uuid ] && echo 12345678-1234-4234-8234-123456789abc\nexit 0\n' > "$2"; }
  render_xray_config() { printf '{}\n'; }
  render_nginx_site() { printf 'server {}\n'; }
  nginx() { return 0; }
  systemctl() { [[ $1 != enable ]]; }
  install_fresh
) >"$tmp/install-log" 2>&1; then
  echo 'accepted a failed service start' >&2
  exit 1
fi
[[ ! -e $tmp/install-etc && ! -e $tmp/install-lib && ! -e $tmp/install-state ]]
[[ ! -e $tmp/install-units/edge-infra-xray-cf.service ]]
[[ ! -e $tmp/install-nginx/cloudflare.conf && ! -e $tmp/install-nginx-enabled/cloudflare.conf ]]
echo 'test-cloudflare-overlay: passed'
