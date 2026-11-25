#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/edge-upgrade-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=../scripts/upgrade-sing-box.sh
source "$root/scripts/upgrade-sing-box.sh"
require_root() { :; }
STATE=$tmp/state; BIN=$tmp/sing-box; BACKUPS=$tmp/backups
mkdir -p "$STATE"
if (preflight) >"$tmp/out" 2>&1; then echo 'accepted pending transaction' >&2; exit 1; fi
grep -q 'pending transaction' "$tmp/out"
mkdir -p "$BACKUPS/upgrade.test123"
printf '#!/bin/sh\nexit 0\n' > "$BACKUPS/upgrade.test123/rollback.sh"
chmod +x "$BACKUPS/upgrade.test123/rollback.sh"
printf '%s\n' "$BACKUPS/upgrade.test123" > "$STATE/backup"
printf '%s\n' edge-infra-upgrade-rollback-test123 > "$STATE/timer"
touch "$BACKUPS/upgrade.test123/rolled-back"
systemctl() { touch "$tmp/systemctl-called"; }
if (finish_upgrade commit) >"$tmp/out" 2>&1; then echo 'committed after automatic rollback' >&2; exit 1; fi
grep -q 'automatic rollback already ran' "$tmp/out"
[[ ! -e $tmp/systemctl-called && -d $STATE ]]

mkdir -p "$tmp/units"
activate() {
  : > "$tmp/units/$1.loaded"
  : > "$tmp/units/$1.active"
  printf '%s\n' "$2" > "$tmp/units/$1.exec"
}
clear_units() { rm -rf "$tmp/units"; mkdir -p "$tmp/units"; }
systemctl() {
  case $1 in
    is-active)
      [[ $2 == --quiet && -f $tmp/units/$3.active ]]
      ;;
    show)
      [[ $3 == -p && $5 == --value ]] || return 1
      case $4 in
        LoadState)
          if [[ -f $tmp/units/$2.loaded ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi
          ;;
        ExecStart) cat "$tmp/units/$2.exec" ;;
        MainPID) printf '424242\n' ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}
readlink() {
  if [[ $1 == /proc/424242/exe ]]; then printf '%s\n' "$BIN"; return 0; fi
  command readlink "$@"
}
NFT_RULES='udp dport 20000-20031 redirect to :443'
nft() { printf '%s\n' "$NFT_RULES"; }

exec_line() { printf '{ path=%s ; argv[]=%s ; }\n' "$1" "$2"; }
expect_discover_fail() {
  if (discover_units) >"$tmp/out" 2>"$tmp/err"; then
    printf '%s\n' "$1" >&2
    exit 1
  fi
  grep -q "$2" "$tmp/err"
}

clear_units
discover_units
[[ ${#SERVICES[@]} -eq 3 && ${#PRESERVE_UNITS[@]} -eq 0 ]]

clear_units
activate sing-box-extra.service "$(exec_line "$BIN" "$BIN run -c $EXTRA_CONFIG")"
rm -f "$tmp/units/sing-box-extra.service.active"
expect_discover_fail 'inactive extra overlay was accepted' 'service inactive: sing-box-extra.service'

clear_units
activate hy2-port-hopping.service "$(exec_line /usr/sbin/nft '/usr/sbin/nft -f /etc/hy2-port-hopping.nft')"
activate edge-infra-port-hopping.service "$(exec_line /usr/sbin/nft '/usr/sbin/nft -f /etc/edge-infra/nftables/hy2-port-hopping.nft')"
expect_discover_fail 'both hopping units were accepted' 'both legacy and repository hopping units are installed'

clear_units
activate edge-infra-xray-cf.service "$(exec_line "$BIN" "$BIN run -c /etc/sing-box/config.json")"
expect_discover_fail 'xray unit sharing sing-box was accepted' 'Xray sidecar unit does not use its own binary'

NFT_RULES='accept'
clear_units
activate hy2-port-hopping.service "$(exec_line /usr/sbin/nft '/usr/sbin/nft -f /etc/hy2-port-hopping.nft')"
expect_discover_fail 'non-redirect hopping table was accepted' 'does not redirect to 443'
NFT_RULES='udp dport 20000-20031 redirect to :443'

clear_units
activate sing-box-extra.service "$(exec_line "$BIN" "$BIN run -c $EXTRA_CONFIG")"
activate hy2-port-hopping.service "$(exec_line /usr/sbin/nft '/usr/sbin/nft -f /etc/hy2-port-hopping.nft')"
activate edge-infra-xray-cf.service "$(exec_line /usr/local/lib/edge-infra-cloudflare/xray '/usr/local/lib/edge-infra-cloudflare/xray run -config %d/xray.json')"
discover_units
[[ ${#SERVICES[@]} -eq 4 && ${SERVICES[3]} == sing-box-extra.service ]]
[[ ${#PRESERVE_UNITS[@]} -eq 2 ]]
[[ ${PRESERVE_UNITS[0]} == hy2-port-hopping.service && ${PRESERVE_UNITS[1]} == edge-infra-xray-cf.service ]]
[[ ${CONFIGS[3]} == "$EXTRA_CONFIG" ]]

rm -rf "$STATE"
CORE_CONFIGS=("$tmp/config.json" "$tmp/trojan.json" "$tmp/reality.json")
EXTRA_CONFIG=$tmp/extra.json
for cfg in "${CORE_CONFIGS[@]}" "$EXTRA_CONFIG"; do printf '{}\n' > "$cfg"; done
printf '#!/bin/sh\nexit 0\n' > "$BIN"
chmod 0755 "$BIN"
activate sing-box.service "$(exec_line "$BIN" "$BIN run -c ${CORE_CONFIGS[0]}")"
activate sing-box-trojan.service "$(exec_line "$BIN" "$BIN run -c ${CORE_CONFIGS[1]}")"
activate sing-box-reality.service "$(exec_line "$BIN" "$BIN run -c ${CORE_CONFIGS[2]}")"
activate sing-box-extra.service "$(exec_line "$BIN" "$BIN run -c $EXTRA_CONFIG")"
preflight >"$tmp/preflight" 2>"$tmp/err"
grep -q 'legacy layout preflight passed' "$tmp/preflight"
grep -q 'sing-box units: sing-box.service sing-box-trojan.service sing-box-reality.service sing-box-extra.service' "$tmp/preflight"
grep -q 'companion units left untouched: hy2-port-hopping.service edge-infra-xray-cf.service' "$tmp/preflight"
grep -q 'hop-port sockets are not required' "$tmp/preflight"
mkdir -p "$tmp/lists"
write_unit_lists "$tmp/lists"
write_rollback_script "$tmp/lists/rollback.sh"
grep -qx 'sing-box-extra.service' "$tmp/lists/services.list"
grep -qx 'hy2-port-hopping.service' "$tmp/lists/preserve.list"
grep -qx 'edge-infra-xray-cf.service' "$tmp/lists/preserve.list"
if grep -Eq 'systemctl restart .*(hy2-port-hopping|edge-infra-xray-cf|nft)' "$tmp/lists/rollback.sh"; then
  echo 'rollback restarts a companion unit' >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -F -q 'systemctl restart "${services[@]}"' "$tmp/lists/rollback.sh"
if grep -Eq 'sysctl|caddy|PasswordAuthentication' "$tmp/lists/rollback.sh" scripts/upgrade-sing-box.sh; then
  echo 'upgrade path gained an out-of-scope mutation' >&2
  exit 1
fi

echo 'test-upgrade-sing-box: passed'
