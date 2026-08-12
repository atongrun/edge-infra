#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

jq empty sing-box/*.json
grep -q 'hop-interval: 20' mihomo/edge.example.yaml
grep -q 'disable-mtu-discovery: true' mihomo/edge.example.yaml
grep -q 'Edge-HY2, Edge-HY2-Hop, Edge-Trojan' mihomo/edge.example.yaml
grep -q 'table inet edge_hy2_port_hopping' nftables/hy2-port-hopping.nft

if grep -RInE --exclude-dir=.git --exclude=verify.sh \
  '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|gh[opsu]_[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|api[_-]?token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]{16,})' .; then
  echo 'Potential secret found' >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git log -p --all -- . | grep -E '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|gh[opsu]_[A-Za-z0-9]{20,})'; then
    echo 'Potential secret found in Git history' >&2
    exit 1
  fi
fi

echo 'Template and secret checks passed'
