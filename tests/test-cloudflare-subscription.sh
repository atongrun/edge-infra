#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/edge-cf-sub.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/input" <<'EOF'
proxies:
- name: DediOne-Reality
- name: DediOne-Trojan
- name: DediOne-HY2
- name: DediOne-HY2-Hop
proxy-groups:
- name: 主链路
  type: fallback
  proxies:
  - DediOne-Reality
  - DediOne-Trojan
  - DediOne-HY2
  - DediOne-HY2-Hop
  interval: 60
rules:
- MATCH,主链路
EOF
printf '%s\n' 12345678-1234-4234-8234-123456789abc > "$tmp/id"
chmod 600 "$tmp/id"
args=(--hostname example.org --path /test-path --uuid-file "$tmp/id")
python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/output" "${args[@]}"
[[ $(grep -c '^- name: DediOne-Cloudflare$' "$tmp/output") == 1 ]]
[[ $(grep -c '^  - DediOne-Cloudflare$' "$tmp/output") == 1 ]]
grep -q '^  interval: 60$' "$tmp/output"
if python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/output" --output "$tmp/duplicate" "${args[@]}" 2>/dev/null; then
  echo 'accepted a duplicate node' >&2; exit 1
fi
if python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/output" "${args[@]}" 2>/dev/null; then
  echo 'overwrote existing candidate' >&2; exit 1
fi
chmod 644 "$tmp/id"
if python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/insecure" "${args[@]}" 2>/dev/null; then
  echo 'accepted an insecure UUID file' >&2; exit 1
fi
echo 'test-cloudflare-subscription: passed'
