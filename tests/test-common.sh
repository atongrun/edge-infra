#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$repo_root/lib/common.sh"

tmpdir=$(mktemp -d /tmp/edge-infra-common-test.XXXXXX)
cleanup() {
  [[ -n ${tmpdir:-} && -d $tmpdir && ! -L $tmpdir ]] || return 0
  case "$tmpdir" in /tmp/*|/var/tmp/*) rm -rf -- "$tmpdir" ;; esac
}
trap cleanup EXIT

write_valid_config() {
  cat > "$1" <<'EOF'
EDGE_DOMAIN=edge.example.com
SUB_DOMAIN=sub.example.com
PUBLIC_IPV4=203.0.113.10
ACME_EMAIL=admin@example.com
HOP_PORT_START=20000
HOP_PORT_END=20031
TROJAN_PORT=8443
FIREWALL_MODE=auto
NETWORK_INTERFACE=eth0
EOF
}

config=$tmpdir/install.env
write_valid_config "$config"
load_config "$config"
[[ $EDGE_DOMAIN == edge.example.com ]]
[[ $HOP_PORT_END == 20031 ]]

cp "$config" "$tmpdir/unknown.env"
printf 'UNKNOWN_KEY=value\n' >> "$tmpdir/unknown.env"
if (load_config "$tmpdir/unknown.env") >/dev/null 2>&1; then
  echo 'unknown config key was accepted' >&2
  exit 1
fi

cp "$config" "$tmpdir/duplicate.env"
printf 'EDGE_DOMAIN=other.example.com\n' >> "$tmpdir/duplicate.env"
if (load_config "$tmpdir/duplicate.env") >/dev/null 2>&1; then
  echo 'duplicate config key was accepted' >&2
  exit 1
fi

sed 's/HOP_PORT_END=20031/HOP_PORT_END=20100/' "$config" > "$tmpdir/wide.env"
if (load_config "$tmpdir/wide.env") >/dev/null 2>&1; then
  echo 'overly broad hopping range was accepted' >&2
  exit 1
fi

secrets=$tmpdir/secrets.env
cat > "$secrets" <<'EOF'
HY2_PASSWORD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TROJAN_PASSWORD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SUBSCRIPTION_TOKEN=cccccccccccccccccccccccccccccccccccccccccccccccc
EOF
load_config "$config"
load_secrets "$secrets"

for template in \
  templates/sing-box/hy2.json \
  templates/sing-box/trojan.json \
  templates/mihomo/edge.yaml \
  templates/nftables/hy2-port-hopping.nft \
  templates/nginx/bootstrap.conf \
  templates/nginx/final.conf \
  templates/systemd/edge-infra-port-hopping.service \
  templates/letsencrypt/reload-edge-infra; do
  output=$tmpdir/$(printf '%s' "$template" | tr / _)
  render_template "$repo_root/$template" "$output"
  if grep -Eq '\$\{(EDGE_DOMAIN|SUB_DOMAIN|PUBLIC_IPV4|ACME_EMAIL|HOP_PORT_START|HOP_PORT_END|TROJAN_PORT|SUBSCRIPTION_FILE|NETWORK_INTERFACE|CERT_NAME|HY2_PASSWORD|TROJAN_PASSWORD)\}' "$output"; then
    echo "unresolved deployment placeholder in $template" >&2
    exit 1
  fi
done

jq empty "$tmpdir/templates_sing-box_hy2.json" "$tmpdir/templates_sing-box_trojan.json"
grep -q 'hop-interval: 20' "$tmpdir/templates_mihomo_edge.yaml"
grep -q '20000-20031' "$tmpdir/templates_mihomo_edge.yaml"
grep -q 'iifname "eth0"' "$tmpdir/templates_nftables_hy2-port-hopping.nft"

echo 'test-common: passed'
