#!/usr/bin/env bash
# Upgrade the explicitly identified legacy layout only; all other layouts fail closed.
set -Eeuo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BIN=/usr/local/bin/sing-box
STATE=/var/lib/edge-infra-sing-box-upgrade
BACKUPS=/var/backups/edge-infra-sing-box-upgrade
SERVICES=(sing-box.service sing-box-trojan.service sing-box-reality.service)
CONFIGS=(/etc/sing-box/config.json /etc/sing-box/trojan.json /etc/sing-box/reality.json)
die() { printf 'upgrade-sing-box: %s\n' "$*" >&2; exit 1; }
require_root() { ((EUID == 0)) || die 'root required'; }
preflight() {
  require_root
  local i exec pid actual known p
  [[ ! -e $STATE && -f $BIN && ! -L $BIN && -x $BIN ]] || die 'pending transaction or unsupported binary layout'
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
  cat > "$backup/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tmp=$(mktemp /usr/local/bin/.edge-rollback.XXXXXX)
trap 'rm -f -- "$tmp"' EXIT
sha256sum -c "$dir/before.sha256" >/dev/null
for c in /etc/sing-box/config.json /etc/sing-box/trojan.json /etc/sing-box/reality.json; do "$dir/old-bin" check -c "$c" >/dev/null; done
cp -a "$dir/old-bin" "$tmp"
mv -f -- "$tmp" /usr/local/bin/sing-box
systemctl restart sing-box.service sing-box-trojan.service sing-box-reality.service
for s in sing-box.service sing-box-trojan.service sing-box-reality.service; do systemctl is-active --quiet "$s"; done
touch "$dir/rolled-back"
EOF
  chmod 0700 "$backup/rollback.sh"
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
    sha256sum -c "$backup/before.sha256" >/dev/null || die 'configuration changed during upgrade'
    [[ $(sha256sum "$BIN" | awk '{print $1}') == "$(cat "$STATE/target.sha256")" ]] || die 'running target binary changed'
    for s in "${SERVICES[@]}"; do systemctl is-active --quiet "$s" || die "inactive service: $s"; done
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
