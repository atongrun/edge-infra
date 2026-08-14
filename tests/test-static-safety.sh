#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if rg -n --glob '*.sh' --glob '*.nft' 'flush[[:space:]]+ruleset|systemctl[[:space:]]+enable[[:space:]]+nftables' .; then
  echo 'global nftables mutation detected' >&2
  exit 1
fi

if rg -n --glob '*.sh' --glob '!test-static-safety.sh' 'curl[^|]*\|[[:space:]]*(ba)?sh'; then
  echo 'curl-pipe-shell pattern detected' >&2
  exit 1
fi

if rg -n --glob '*.sh' --glob '!test-static-safety.sh' 'curl[^\n]*http://'; then
  echo 'insecure HTTP download detected' >&2
  exit 1
fi

grep -q 'SING_BOX_AMD64_SHA256=' versions.env
grep -q 'SING_BOX_ARM64_SHA256=' versions.env
grep -q "comment 'edge-infra" bin/edge-infra
grep -q 'safe_remove_tree' bin/edge-infra

echo 'test-static-safety: passed'
