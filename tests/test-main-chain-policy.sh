#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../scripts/reality-overlay.sh
source "$repo_root/scripts/reality-overlay.sh"

tmpdir=$(mktemp -d /tmp/edge-infra-main-chain-test.XXXXXX)
cleanup() {
  [[ -n ${tmpdir:-} && -d $tmpdir && ! -L $tmpdir ]] || return 0
  case "$tmpdir" in /tmp/*|/var/tmp/*) rm -rf -- "$tmpdir" ;; esac
}
trap cleanup EXIT

input=$tmpdir/input.yaml
output=$tmpdir/output.yaml
cat > "$input" <<'EOF'
proxies:
- name: DediOne-HY2
  type: hysteria2
- name: DediOne-HY2-Hop
  type: hysteria2
- name: DediOne-Trojan
  type: trojan
- name: DediOne-Reality
  type: vless
proxy-groups:
- name: PROXY
  type: fallback
  proxies:
  - DediOne-HY2
  - DediOne-HY2-Hop
  - DediOne-Trojan
- name: Proxies
  type: select
  proxies:
  - PROXY
  - DediOne-Reality
- name: OpenAI
  type: select
  proxies:
  - PROXY
  - DediOne-Reality
rules:
- DOMAIN-SUFFIX,openai.com,PROXY
- DOMAIN-SUFFIX,chatgpt.com,OpenAI
- MATCH,Proxies
profile:
  store-selected: true
dns:
  nameserver:
  - 223.5.5.5
EOF

render_main_chain "$input" "$output"

[[ $(grep -c '^- name: 主链路$' "$output") == 1 ]]
if grep -Eq '^- name: (PROXY|Proxies|OpenAI)$' "$output"; then
  echo 'legacy proxy group survived main-chain rendering' >&2
  exit 1
fi
[[ $(grep -c '^  - DediOne-Reality$' "$output") == 1 ]]
[[ $(grep -c '^  - DediOne-Trojan$' "$output") == 1 ]]
[[ $(grep -c '^  - DediOne-HY2$' "$output") == 1 ]]
[[ $(grep -c '^  - DediOne-HY2-Hop$' "$output") == 1 ]]

actual_order=$(awk '
  $0 == "- name: 主链路" {in_group=1; next}
  in_group && /^- name:/ {in_group=0}
  in_group && /^  - / {sub(/^  - /, ""); print}
' "$output")
expected_order=$'DediOne-Reality\nDediOne-Trojan\nDediOne-HY2\nDediOne-HY2-Hop'
[[ $actual_order == "$expected_order" ]]

grep -q '^- DOMAIN-SUFFIX,openai.com,主链路$' "$output"
grep -q '^- DOMAIN-SUFFIX,chatgpt.com,主链路$' "$output"
grep -q '^- MATCH,主链路$' "$output"
grep -q '^  - 223.5.5.5$' "$output"

echo 'test-main-chain-policy: passed'
