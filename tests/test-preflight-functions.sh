#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

EDGE_INFRA_SOURCE_ONLY=1
# shellcheck source=../bin/edge-infra
source bin/edge-infra

PUBLIC_IPV4=8.8.8.8
MOCK_DNS=''
getent() {
  [[ -n $MOCK_DNS ]] && printf '%s\n' "$MOCK_DNS"
}

MOCK_DNS='8.8.8.8 STREAM edge.example.com'
check_dns edge.example.com

MOCK_DNS=''
if (check_dns edge.example.com) >/dev/null 2>&1; then
  printf 'empty DNS result unexpectedly passed\n' >&2
  exit 1
fi

MOCK_DNS='1.1.1.1 STREAM edge.example.com'
if (check_dns edge.example.com) >/dev/null 2>&1; then
  printf 'wrong DNS result unexpectedly passed\n' >&2
  exit 1
fi

MOCK_DNS=$'8.8.8.8 STREAM edge.example.com\n1.1.1.1 STREAM edge.example.com'
if (check_dns edge.example.com) >/dev/null 2>&1; then
  printf 'ambiguous DNS result unexpectedly passed\n' >&2
  exit 1
fi

install_body=$(sed -n '/^install_cmd()/,/^}/p' bin/edge-infra)
acme_rule_line=$(grep -n '^[[:space:]]*add_acme_ufw_rule$' <<<"$install_body" | cut -d: -f1)
certbot_line=$(grep -n '^[[:space:]]*configure_certificate_and_nginx$' <<<"$install_body" | cut -d: -f1)
[[ -n $acme_rule_line && -n $certbot_line && $acme_rule_line -lt $certbot_line ]]

download_tmp=$(mktemp -d /tmp/edge-infra-download-test.XXXXXX)
cleanup_download_tmp "$download_tmp"
[[ ! -e $download_tmp ]]

if (cleanup_download_tmp /tmp) >/dev/null 2>&1; then
  printf 'broad temporary cleanup target unexpectedly passed\n' >&2
  exit 1
fi

printf 'test-preflight-functions: passed\n'
