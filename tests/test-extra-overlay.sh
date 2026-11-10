#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d /tmp/edge-infra-extra-test.XXXXXX)
trap 'case "$tmpdir" in /tmp/*) rm -rf -- "$tmpdir" ;; esac' EXIT

cat > "$tmpdir/input.yaml" <<'YAML'
mixed-port: 7890
proxies:
- name: DediOne-HY2
  type: hysteria2
- name: DediOne-Trojan
  type: trojan
- name: DediOne-HY2-Hop
  type: hysteria2
- name: DediOne-Reality
  type: vless
proxy-groups:
- name: 主链路
  type: fallback
  proxies:
  - DediOne-Reality
  - DediOne-Trojan
  - DediOne-HY2
  - DediOne-HY2-Hop
  url: https://www.gstatic.com/generate_204
  interval: 60
rules:
- MATCH,主链路
dns:
  nameserver:
  - https://1.1.1.1/dns-query#主链路
YAML

(
  # shellcheck source=../scripts/extra-overlay.sh
  source "$repo_root/scripts/extra-overlay.sh"
  trap - EXIT
  EXTRA_SERVER=edge.example.com; EXTRA_SERVER_NAME=edge.example.com
  ANYTLS_PORT=8444; TUIC_PORT=8443
  ANYTLS_PASSWORD=test-anytls; TUIC_UUID=00000000-0000-4000-8000-000000000000; TUIC_PASSWORD=test-tuic
  render_client_nodes > "$tmpdir/nodes.yaml"
  render_subscription "$tmpdir/input.yaml" "$tmpdir/nodes.yaml" "$tmpdir/output.yaml"
  CERT_PATH=/c.pem; KEY_PATH=/k.pem
  render_extra_config | jq -e '.inbounds | length == 2 and .[0].type == "anytls" and .[1].type == "tuic"' >/dev/null
)

expected=$'DediOne-Reality\nDediOne-Trojan\nDediOne-HY2\nDediOne-HY2-Hop\nDediOne-AnyTLS\nDediOne-TUIC'
actual=$(awk '$0 == "- name: 主链路" {g=1; next} g && /^[A-Za-z0-9_-]+:$/ {g=0} g && /^  - / {sub(/^  - /, ""); print}' "$tmpdir/output.yaml")
[[ $actual == "$expected" ]]
python3 - "$tmpdir/input.yaml" "$tmpdir/output.yaml" <<'PY'
import sys, yaml
src = open(sys.argv[1]).read().splitlines()
out = open(sys.argv[2]).read().splitlines()
# Only additions: every original line survives, in order.
it = iter(out)
assert all(line in it for line in src), "original line removed or reordered"
assert len(out) - len(src) == 24, len(out) - len(src)
d = yaml.safe_load(open(sys.argv[2]))
names = [p["name"] for p in d["proxies"]]
assert names[-2:] == ["DediOne-AnyTLS", "DediOne-TUIC"], names
g = d["proxy-groups"][0]
assert g["proxies"][-2:] == ["DediOne-AnyTLS", "DediOne-TUIC"]
assert d["rules"] == ["MATCH,主链路"]
PY

# The Reality overlay's main-chain check accepts the extra nodes only with extra state.
(
  # shellcheck source=../scripts/reality-overlay.sh
  source "$repo_root/scripts/reality-overlay.sh"
  trap - EXIT
  CF_STATE_FILE=$tmpdir/cf-missing
  EXTRA_STATE_FILE=$tmpdir/extra-missing
  if (check_main_chain "$tmpdir/output.yaml") 2>/dev/null; then exit 1; fi
  : > "$tmpdir/extra-state"
  EXTRA_STATE_FILE=$tmpdir/extra-state
  check_main_chain "$tmpdir/output.yaml"
)
echo 'extra overlay rendering ok'
