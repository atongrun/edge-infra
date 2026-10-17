#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-traffic-test.XXXXXX)
cleanup() {
  [[ -n ${tmpdir:-} && -d $tmpdir && ! -L $tmpdir ]] || return 0
  case "$tmpdir" in /tmp/*|/var/tmp/*) rm -rf -- "$tmpdir" ;; esac
}
trap cleanup EXIT

mkdir "$tmpdir/bin"
cat > "$tmpdir/bin/vnstat" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"vnstatversion":"2.12","jsonversion":"2","interfaces":[{"name":"eth0","updated":{"timestamp":1792240500},"traffic":{"month":[{"date":{"year":2099,"month":7},"rx":1234,"tx":5678}]}}]}
JSON
EOF
cat > "$tmpdir/bin/date" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  +%Y) echo 2099 ;;
  +%m) echo 07 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmpdir/bin/vnstat" "$tmpdir/bin/date"

cat > "$tmpdir/traffic.env" <<'EOF'
NETWORK_INTERFACE=eth0
TOTAL_BYTES=536870912000
SNIPPET_PATH=/etc/nginx/snippets/edge-infra-traffic/subscription-userinfo.conf
EOF

actual=$(PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/traffic.env" \
  "$repo_root/scripts/traffic-header.sh" render)
expected='add_header Subscription-Userinfo "upload=1234; download=5678; total=536870912000" always;'
[[ $actual == "$expected"$'\n''add_header X-Traffic-Sampled-At "1792240500" always;' ]]
[[ $(grep -c "^add_header" <<<"$actual") == 2 ]]
for mode in rx tx; do
  cp "$tmpdir/traffic.env" "$tmpdir/$mode.env"
  printf 'BILLING_MODE=%s\n' "$mode" >> "$tmpdir/$mode.env"
  actual=$(PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/$mode.env" \
    "$repo_root/scripts/traffic-header.sh" render)
  actual=${actual%%$'\n'*}
  case "$mode" in
    rx) [[ $actual == 'add_header Subscription-Userinfo "upload=1234; download=0; total=536870912000" always;' ]] ;;
    tx) [[ $actual == 'add_header Subscription-Userinfo "upload=0; download=5678; total=536870912000" always;' ]] ;;
  esac
done
# A decimal package retains its exact quota; this is not a global 500 GiB default.
sed 's/536870912000/500000000000/' "$tmpdir/traffic.env" > "$tmpdir/decimal.env"
actual=$(PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/decimal.env" \
  "$repo_root/scripts/traffic-header.sh" render)
[[ $actual == *'total=500000000000'* ]]
# The timestamp comes from the same vnStat JSON snapshot, never the render clock.
cp "$tmpdir/bin/vnstat" "$tmpdir/good-vnstat"
sed 's/"updated":{"timestamp":1792240500},//' "$tmpdir/good-vnstat" > "$tmpdir/bin/vnstat"
if PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/traffic.env" \
  "$repo_root/scripts/traffic-header.sh" render > "$tmpdir/no-timestamp" 2>/dev/null; then
  echo 'missing sample timestamp accepted' >&2; exit 1
fi
[[ ! -s $tmpdir/no-timestamp ]]
cp "$tmpdir/good-vnstat" "$tmpdir/bin/vnstat"
grep -Fxq 'TOTAL_BYTES=536870912000' "$repo_root/env/dedione-500gib-traffic.env.example"
printf 'BILLING_MODE=invalid\n' >> "$tmpdir/traffic.env"
if PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/traffic.env" \
  "$repo_root/scripts/traffic-header.sh" render > /dev/null 2>&1; then
  echo 'invalid billing mode accepted' >&2; exit 1
fi
sed -i.bak '/BILLING_MODE=/d' "$tmpdir/traffic.env"
cat > "$tmpdir/bin/vnstat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
if PATH="$tmpdir/bin:$PATH" EDGE_INFRA_TRAFFIC_CONFIG="$tmpdir/traffic.env" \
  "$repo_root/scripts/traffic-header.sh" render > "$tmpdir/failed-render" 2>/dev/null; then
  echo 'failed vnstat accepted' >&2; exit 1
fi
[[ ! -s $tmpdir/failed-render ]]

grep -Fq 'include /etc/nginx/snippets/edge-infra-traffic/subscription-userinfo.conf;' \
  "$repo_root/templates/nginx/final.conf"
grep -Fq 'OnCalendar=hourly' "$repo_root/templates/systemd/edge-infra-traffic.timer"
grep -Fxq 'ProtectSystem=strict' "$repo_root/templates/systemd/edge-infra-traffic.service"
grep -Fxq \
  'ReadWritePaths=/etc/nginx/snippets/edge-infra-traffic /var/log/nginx/access.log' \
  "$repo_root/templates/systemd/edge-infra-traffic.service"

echo 'test-traffic-header: passed'
