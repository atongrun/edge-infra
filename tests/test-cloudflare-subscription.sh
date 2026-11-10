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
cp "$tmp/input" "$tmp/original"
printf '%s\n' 12345678-1234-4234-8234-123456789abc > "$tmp/id"
chmod 600 "$tmp/id"
args=(--hostname edge.example.org --path /test-path --uuid-file "$tmp/id")
python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/output" "${args[@]}"
[[ $(grep -c '^- name: DediOne-Cloudflare$' "$tmp/output") == 1 ]]
[[ $(grep -c '^  - DediOne-Cloudflare$' "$tmp/output") == 1 ]]
grep -q '^  interval: 60$' "$tmp/output"
grep -q '^  type: fallback$' "$tmp/output"
grep -q '^  type: vless$' "$tmp/output"
grep -q '^  udp: false$' "$tmp/output"
grep -q '^  network: xhttp$' "$tmp/output"
grep -q '^  tls: true$' "$tmp/output"
grep -q '^  alpn: \[h2\]$' "$tmp/output"
grep -q '^  servername: edge.example.org$' "$tmp/output"
grep -q '^    mode: packet-up$' "$tmp/output"
grep -q '^    host: edge.example.org$' "$tmp/output"
grep -q '^      Host: edge.example.org$' "$tmp/output"
grep -q '^    path: /test-path$' "$tmp/output"
if grep -Eq 'mux|smux|network: ws|ws-opts|skip-cert-verify|network: grpc|url-test' "$tmp/output"; then
  echo 'candidate contains a forbidden legacy or mux setting' >&2
  exit 1
fi
[[ $(grep -c '^  server: edge.example.org$' "$tmp/output") == 1 ]]
actual_order=$(awk '
  $0 == "- name: 主链路" {in_group=1; next}
  in_group && /^[A-Za-z0-9_-]+:$/ {in_group=0}
  in_group && /^  - / {sub(/^  - /, ""); print}
' "$tmp/output")
expected_order=$'DediOne-Reality\nDediOne-Trojan\nDediOne-HY2\nDediOne-HY2-Hop\nDediOne-Cloudflare'
[[ $actual_order == "$expected_order" ]]
cmp -s "$tmp/input" "$tmp/original"

# A preferred anycast IP changes only server; SNI/Host stay on the hostname.
python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/ip" \
  --preferred-ip 203.0.113.10 "${args[@]}"
grep -q '^  server: 203.0.113.10$' "$tmp/ip"
grep -q '^  servername: edge.example.org$' "$tmp/ip"
grep -q '^    host: edge.example.org$' "$tmp/ip"
grep -q '^      Host: edge.example.org$' "$tmp/ip"

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
chmod 600 "$tmp/id"
if python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/badpath" \
  --hostname edge.example.org --path '/bad path' --uuid-file "$tmp/id" 2>/dev/null; then
  echo 'accepted an invalid XHTTP path' >&2; exit 1
fi
if python3 "$root/scripts/cloudflare-subscription.py" --source "$tmp/input" --output "$tmp/badip" \
  --hostname edge.example.org --path /test-path --uuid-file "$tmp/id" \
  --preferred-ip not-an-ip 2>/dev/null; then
  echo 'accepted an invalid preferred IP' >&2; exit 1
fi
echo 'test-cloudflare-subscription: passed'
