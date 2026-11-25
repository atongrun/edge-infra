#!/usr/bin/env bash
# Upgrade one legacy sing-box binary layout. Fresh edge-infra installs use a
# symlink and are rejected. Companion units that do not execute this binary
# are checked and left running.
set -Eeuo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BIN=/usr/local/bin/sing-box
STATE=/var/lib/edge-infra-sing-box-upgrade
BACKUPS=/var/backups/edge-infra-sing-box-upgrade
CORE_SERVICES=(sing-box.service sing-box-trojan.service sing-box-reality.service)
CORE_CONFIGS=(/etc/sing-box/config.json /etc/sing-box/trojan.json /etc/sing-box/reality.json)
EXTRA_SERVICE=sing-box-extra.service
EXTRA_CONFIG=/etc/sing-box/extra.json
HOP_UNITS=(hy2-port-hopping.service edge-infra-port-hopping.service)
XRAY_UNIT=edge-infra-xray-cf.service
SERVICES=()
CONFIGS=()
PRESERVE_UNITS=()
die() { printf 'upgrade-sing-box: %s\n' "$*" >&2; exit 1; }
require_root() { ((EUID == 0)) || die 'root required'; }

check_hop_table() {
  local unit=$1 family name rules
  case $unit in
    hy2-port-hopping.service) family=inet; name=edge_hy2_port_hopping ;;
    edge-infra-port-hopping.service) family=inet; name=edge_infra_hy2_hopping ;;
    *) die "unknown hopping unit: $unit" ;;
  esac
  command -v nft >/dev/null 2>&1 || return 0
  rules=$(nft list table "$family" "$name") || die "hopping table $family $name is not loaded"
  [[ $rules == *'redirect to :443'* ]] || die "hopping table $family $name does not redirect to 443"
}

discover_units() {
  local load exec unit hops=0
  SERVICES=("${CORE_SERVICES[@]}")
  CONFIGS=("${CORE_CONFIGS[@]}")
  PRESERVE_UNITS=()
  load=$(systemctl show "$EXTRA_SERVICE" -p LoadState --value 2>/dev/null || true)
  if [[ -n $load && $load != not-found ]]; then
    systemctl is-active --quiet "$EXTRA_SERVICE" \
      || die "service inactive: $EXTRA_SERVICE (AnyTLS/TUIC stays installed; it is not skipped)"
    exec=$(systemctl show "$EXTRA_SERVICE" -p ExecStart --value)
    [[ $exec == *"path=$BIN "* && $exec == *"-c $EXTRA_CONFIG "* ]] \
      || die "unexpected ExecStart: $EXTRA_SERVICE"
    SERVICES+=("$EXTRA_SERVICE")
    CONFIGS+=("$EXTRA_CONFIG")
  fi
  for unit in "${HOP_UNITS[@]}"; do
    load=$(systemctl show "$unit" -p LoadState --value 2>/dev/null || true)
    [[ -n $load && $load != not-found ]] || continue
    systemctl is-active --quiet "$unit" || die "service inactive: $unit"
    exec=$(systemctl show "$unit" -p ExecStart --value)
    [[ $exec == *nft* && $exec != *sing-box* ]] || die "hopping unit is not an nft redirect: $unit"
    check_hop_table "$unit"
    PRESERVE_UNITS+=("$unit")
    hops=$((hops + 1))
  done
  ((hops <= 1)) || die 'both legacy and repository hopping units are installed'
  load=$(systemctl show "$XRAY_UNIT" -p LoadState --value 2>/dev/null || true)
  if [[ -n $load && $load != not-found ]]; then
    systemctl is-active --quiet "$XRAY_UNIT" || die "service inactive: $XRAY_UNIT"
    exec=$(systemctl show "$XRAY_UNIT" -p ExecStart --value)
    [[ $exec == *xray* && $exec != *sing-box* && $exec != *"path=$BIN "* ]] \
      || die 'Xray sidecar unit does not use its own binary'
    PRESERVE_UNITS+=("$XRAY_UNIT")
  fi
}

preflight() {
  require_root
  local i exec pid actual known p unit
  [[ ! -e $STATE && -f $BIN && ! -L $BIN && -x $BIN ]] || die 'pending transaction or unsupported binary layout'
  discover_units
  for ((i=0;i<${#SERVICES[@]};i++)); do
    systemctl is-active --quiet "${SERVICES[i]}" || die "service inactive: ${SERVICES[i]}"
    exec=$(systemctl show "${SERVICES[i]}" -p ExecStart --value)
    [[ $exec == *"path=$BIN "* && $exec == *"-c ${CONFIGS[i]} "* ]] || die "unexpected ExecStart: ${SERVICES[i]}"
    [[ -f ${CONFIGS[i]} && ! -L ${CONFIGS[i]} ]] || die 'unsupported configuration path'
    "$BIN" check -c "${CONFIGS[i]}" >/dev/null
    pid=$(systemctl show "${SERVICES[i]}" -p MainPID --value)
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die 'missing service PID'
    actual=$(readlink "/proc/$pid/exe")
    [[ $actual == "$BIN" ]] || die 'running binary does not match expected path'
  done
  for p in /proc/[0-9]*/exe; do
    actual=$(readlink "$p" 2>/dev/null || true)
    [[ $actual == "$BIN" ]] || continue
    pid=${p#/proc/}; pid=${pid%/exe}; known=0
    for i in "${SERVICES[@]}"; do [[ $(systemctl show "$i" -p MainPID --value) != "$pid" ]] || known=1; done
    ((known)) || die 'unmanaged process uses the target binary'
  done
  case $(uname -m) in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) die 'unsupported architecture';; esac
  echo 'legacy layout preflight passed'
  echo "sing-box units: ${SERVICES[*]}"
  if ((${#PRESERVE_UNITS[@]})); then
    echo "companion units left untouched: ${PRESERVE_UNITS[*]}"
  else
    echo 'companion units left untouched: none'
  fi
  for unit in "${PRESERVE_UNITS[@]}"; do
    case $unit in
      hy2-port-hopping.service|edge-infra-port-hopping.service)
        echo 'hop-port sockets are not required; hopping is an nft redirect to 443'
        ;;
    esac
  done
}

write_unit_lists() {
  local dir=$1 line
  : > "$dir/services.list"
  : > "$dir/configs.list"
  : > "$dir/preserve.list"
  for line in "${SERVICES[@]}"; do printf '%s\n' "$line" >> "$dir/services.list"; done
  for line in "${CONFIGS[@]}"; do printf '%s\n' "$line" >> "$dir/configs.list"; done
  for line in "${PRESERVE_UNITS[@]}"; do printf '%s\n' "$line" >> "$dir/preserve.list"; done
}

load_transaction_lists() {
  local backup=$1 line found core service
  [[ -f $backup/services.list && -f $backup/configs.list && -f $backup/preserve.list ]] \
    || die 'transaction unit lists are missing'
  SERVICES=(); CONFIGS=(); PRESERVE_UNITS=()
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    case $line in
      sing-box.service|sing-box-trojan.service|sing-box-reality.service|sing-box-extra.service) ;;
      *) die "unexpected service in transaction: $line" ;;
    esac
    SERVICES+=("$line")
  done < "$backup/services.list"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    case $line in
      /etc/sing-box/config.json|/etc/sing-box/trojan.json|/etc/sing-box/reality.json|/etc/sing-box/extra.json) ;;
      *) die "unexpected config in transaction: $line" ;;
    esac
    CONFIGS+=("$line")
  done < "$backup/configs.list"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    case $line in
      hy2-port-hopping.service|edge-infra-port-hopping.service|edge-infra-xray-cf.service) ;;
      *) die "unexpected companion in transaction: $line" ;;
    esac
    PRESERVE_UNITS+=("$line")
  done < "$backup/preserve.list"
  for core in sing-box.service sing-box-trojan.service sing-box-reality.service; do
    found=0
    for service in "${SERVICES[@]}"; do [[ $service == "$core" ]] && found=1; done
    ((found)) || die "transaction is missing $core"
  done
}

write_rollback_script() {
  local dest=$1
  cat > "$dest" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
[[ -s $dir/services.list && -s $dir/configs.list && -f $dir/preserve.list ]] || exit 1
services=()
while IFS= read -r service; do
  [[ -n $service ]] || continue
  case $service in
    sing-box.service|sing-box-trojan.service|sing-box-reality.service|sing-box-extra.service) ;;
    *) exit 1 ;;
  esac
  services+=("$service")
done < "$dir/services.list"
((${#services[@]})) || exit 1
while IFS= read -r config; do
  [[ -n $config ]] || continue
  case $config in
    /etc/sing-box/config.json|/etc/sing-box/trojan.json|/etc/sing-box/reality.json|/etc/sing-box/extra.json) ;;
    *) exit 1 ;;
  esac
done < "$dir/configs.list"
while IFS= read -r service; do
  [[ -n $service ]] || continue
  case $service in
    hy2-port-hopping.service|edge-infra-port-hopping.service|edge-infra-xray-cf.service) ;;
    *) exit 1 ;;
  esac
done < "$dir/preserve.list"
tmp=$(mktemp /usr/local/bin/.edge-rollback.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
sha256sum -c "$dir/before.sha256" >/dev/null
while IFS= read -r config; do
  [[ -n $config ]] || continue
  "$dir/old-bin" check -c "$config" >/dev/null
done < "$dir/configs.list"
cp -a "$dir/old-bin" "$tmp"
mv -f -- "$tmp" /usr/local/bin/sing-box
systemctl restart "${services[@]}"
for service in "${services[@]}"; do systemctl is-active --quiet "$service"; done
while IFS= read -r service; do
  [[ -n $service ]] || continue
  systemctl is-active --quiet "$service"
done < "$dir/preserve.list"
touch "$dir/rolled-back"
EOF
  chmod 0700 "$dest"
}

start_upgrade() {
  preflight
  # shellcheck disable=SC1091
  source "$ROOT/env/resilience-versions.env.example"
  local sha tmp backup token timer i installed=0
  [[ $ARCH == amd64 ]] && sha=$UPGRADE_SING_BOX_AMD64_SHA256 || sha=$UPGRADE_SING_BOX_ARM64_SHA256
  tmp=$(mktemp -d /tmp/edge-upgrade.XXXXXX)
  trap 'rm -rf -- "$tmp"' RETURN
  curl -fsSL --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$UPGRADE_SING_BOX_VERSION/sing-box-$UPGRADE_SING_BOX_VERSION-linux-$ARCH.tar.gz" -o "$tmp/pkg"
  printf '%s  %s\n' "$sha" "$tmp/pkg" | sha256sum -c --status || die 'package checksum mismatch'
  tar -xzf "$tmp/pkg" -C "$tmp" "sing-box-$UPGRADE_SING_BOX_VERSION-linux-$ARCH/sing-box"
  install -m 0755 "$tmp/sing-box-$UPGRADE_SING_BOX_VERSION-linux-$ARCH/sing-box" "$tmp/new"
  for i in "${CONFIGS[@]}"; do "$tmp/new" check -c "$i" >/dev/null || die 'new binary rejects existing config'; done
  install -d -m 0700 "$BACKUPS"
  backup=$(mktemp -d "$BACKUPS/upgrade.XXXXXXXX")
  token=${backup##*.}; timer=edge-infra-upgrade-rollback-$token
  cp -a "$BIN" "$backup/old-bin"
  for ((i=0;i<${#SERVICES[@]};i++)); do
    cp -a "${CONFIGS[i]}" "$backup/config-$i.json"
    systemctl cat "${SERVICES[i]}" > "$backup/unit-$i.txt"
  done
  sha256sum "$backup/old-bin" "${CONFIGS[@]}" > "$backup/before.sha256"
  write_unit_lists "$backup"
  write_rollback_script "$backup/rollback.sh"
  install -d -m 0700 "$STATE"
  printf '%s\n' "$backup" > "$STATE/backup"
  printf '%s\n' "$timer" > "$STATE/timer"
  sha256sum "$tmp/new" | awk '{print $1}' > "$STATE/target.sha256"
  if ! systemd-run --quiet --unit="$timer" --on-active=15m --timer-property=AccuracySec=1s /bin/bash "$backup/rollback.sh"; then rm -rf "$STATE"; die 'could not arm rollback timer'; fi
  systemctl is-active --quiet "$timer.timer" || die 'rollback timer did not become active'
  # Prepare the new file next to the target so rename is atomic.
  local next
  next=$(mktemp /usr/local/bin/.edge-upgrade-new.XXXXXX)
  if install -m 0755 "$tmp/new" "$next" && mv -f "$next" "$BIN"; then installed=1; else rm -f "$next"; fi
  local healthy=1
  if (( installed )) && systemctl restart "${SERVICES[@]}"; then
    for i in "${SERVICES[@]}"; do systemctl is-active --quiet "$i" || healthy=0; done
    for i in "${PRESERVE_UNITS[@]}"; do systemctl is-active --quiet "$i" || healthy=0; done
  else healthy=0; fi
  if (( ! healthy )); then
    "$backup/rollback.sh" || die 'upgrade failed and immediate rollback failed; timer remains armed'
    systemctl stop "$timer.timer" || true
    rm -rf "$STATE"
    die 'upgrade failed; old binary restored'
  fi
  echo 'upgrade running; independent rollback timer remains armed for 15 minutes'
  echo 'Run external acceptance, then explicitly run upgrade-sing-box.sh commit --yes.'
}
finish_upgrade() {
  [[ -f $STATE/backup && -f $STATE/timer ]] || die 'no pending upgrade transaction'
  local backup timer s
  backup=$(cat "$STATE/backup"); timer=$(cat "$STATE/timer")
  [[ $backup == "$BACKUPS"/upgrade.* && $timer =~ ^edge-infra-upgrade-rollback-[A-Za-z0-9]+$ && -x $backup/rollback.sh ]] || die 'invalid transaction state'
  if [[ $1 == commit ]]; then
    [[ ! -e $backup/rolled-back ]] || die 'automatic rollback already ran; inspect state'
    systemctl is-active --quiet "$timer.timer" || die 'rollback timer is not active'
    load_transaction_lists "$backup"
    sha256sum -c "$backup/before.sha256" >/dev/null || die 'configuration changed during upgrade'
    [[ $(sha256sum "$BIN" | awk '{print $1}') == "$(cat "$STATE/target.sha256")" ]] || die 'running target binary changed'
    for s in "${SERVICES[@]}"; do systemctl is-active --quiet "$s" || die "inactive service: $s"; done
    for s in "${PRESERVE_UNITS[@]}"; do systemctl is-active --quiet "$s" || die "inactive companion: $s"; done
  else
    "$backup/rollback.sh"
  fi
  systemctl stop "$timer.timer"
  if [[ $1 == commit ]] && { [[ -e $backup/rolled-back ]] || systemctl is-active --quiet "$timer.service"; }; then
    die 'rollback raced with commit; inspect service and transaction state'
  fi
  rm -rf "$STATE"
  echo "$1 complete; private backup retained"
}
main() {
  require_root
  local command=${1:-} yes=${2:-}
  exec 9>/run/lock/edge-infra-sing-box-upgrade.lock
  flock -n 9 || die 'another upgrade operation is running'
  case $command in
    preflight) preflight;;
    upgrade) [[ $yes == --yes ]] || die 'upgrade requires --yes'; start_upgrade;;
    commit|rollback) [[ $yes == --yes ]] || die "$command requires --yes"; finish_upgrade "$command";;
    *) die 'usage: upgrade-sing-box.sh preflight|upgrade|commit|rollback [--yes]';;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
