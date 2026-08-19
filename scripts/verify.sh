#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"

for file in bin/edge-infra lib/common.sh scripts/*.sh tests/*.sh templates/letsencrypt/*; do
  bash -n "$file"
done

grep -q 'hop-interval: 20' templates/mihomo/edge.yaml
grep -q 'disable-mtu-discovery: true' templates/mihomo/edge.yaml
grep -q 'name: 主链路' templates/mihomo/edge.yaml
grep -q 'Edge-Trojan, Edge-HY2, Edge-HY2-Hop' templates/mihomo/edge.yaml
! grep -Eq 'name: (PROXY|Proxies|OpenAI)' templates/mihomo/edge.yaml
grep -q 'table inet edge_infra_hy2_hopping' templates/nftables/hy2-port-hopping.nft
grep -Eq '^SING_BOX_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' versions.env
grep -Eq '^SING_BOX_AMD64_SHA256=[a-f0-9]{64}$' versions.env
grep -Eq '^SING_BOX_ARM64_SHA256=[a-f0-9]{64}$' versions.env
git ls-files --error-unmatch versions.env >/dev/null
grep -q '^MIT License$' LICENSE

if git ls-files | grep -E '(^|/)[^/]*\.env$|(^|/)secrets\.[^/]+$' | grep -vE '\.example$|^versions\.env$'; then
  echo 'Tracked runtime environment or secret file found' >&2
  exit 1
fi

if grep -RInE --exclude-dir=.git --exclude=verify.sh \
  '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|gh[opsu]_[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|api[_-]?token[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]{16,}|188\.255\.|edge\.atong\.run|sub\.atong\.run)' .; then
  echo 'Potential secret found' >&2
  exit 1
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git log -p --all -- . | grep -E '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|gh[opsu]_[A-Za-z0-9]{20,}|188\.255\.|edge\.atong\.run|sub\.atong\.run)'; then
    echo 'Potential secret found in Git history' >&2
    exit 1
  fi
fi

echo 'Repository and secret checks passed'
