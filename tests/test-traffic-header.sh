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
{"vnstatversion":"2.12","jsonversion":"2","interfaces":[{"name":"eth0","traffic":{"month":[{"date":{"year":2099,"month":7},"rx":1234,"tx":5678}]}}]}
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
[[ $actual == "$expected" ]]

grep -Fq 'include /etc/nginx/snippets/edge-infra-traffic/subscription-userinfo.conf;' \
  "$repo_root/templates/nginx/final.conf"
grep -Fq 'OnCalendar=hourly' "$repo_root/templates/systemd/edge-infra-traffic.timer"
grep -Fxq 'ProtectSystem=strict' "$repo_root/templates/systemd/edge-infra-traffic.service"
grep -Fxq \
  'ReadWritePaths=/etc/nginx/snippets/edge-infra-traffic /var/log/nginx/access.log' \
  "$repo_root/templates/systemd/edge-infra-traffic.service"

echo 'test-traffic-header: passed'
