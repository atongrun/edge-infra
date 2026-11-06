#!/usr/bin/env bash
# Publish the optional Cloudflare XHTTP node behind a validated, reversible transaction.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
GENERATOR=$SCRIPT_DIR/cloudflare-subscription.py
REALITY_OVERLAY=$SCRIPT_DIR/reality-overlay.sh
STATE=${CF_STATE_DIR_OVERRIDE:-/var/lib/edge-infra-cloudflare}
STATE_FILE=$STATE/state.env
REALITY_STATE=${EDGE_INFRA_REALITY_STATE:-/var/lib/edge-infra-reality/state.env}
REALITY_CLI=${EDGE_INFRA_REALITY_CLI:-/usr/local/sbin/edge-infra-reality}
BACKUPS=${CF_BACKUP_ROOT_OVERRIDE:-/var/backups/edge-infra-cloudflare}
TRANSACTION=$STATE/subscription-transaction.env
RESTORE=$STATE/restore-subscription.sh
TIMER=''
VERSIONS_FILE=${RESILIENCE_VERSIONS_FILE:-$ROOT/env/resilience-versions.env.example}

die() { printf 'cloudflare-subscription: %s\n' "$*" >&2; exit 1; }
log() { printf '[edge-infra-cloudflare] %s\n' "$*"; }
require_root() { ((EUID == 0)) || die 'root required'; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

load_overlay_state() {
  [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die 'Cloudflare overlay is not installed'
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

load_versions() {
  [[ -f $VERSIONS_FILE && ! -L $VERSIONS_FILE ]] || die 'resilience version manifest is missing'
  # shellcheck disable=SC1090
  source "$VERSIONS_FILE"
  [[ ${MIHOMO_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'MIHOMO_VERSION is invalid'
  case $(uname -m) in
    x86_64) ARCH=amd64; MIHOMO_SHA=${MIHOMO_AMD64_SHA256:-} ;;
    aarch64|arm64) ARCH=arm64; MIHOMO_SHA=${MIHOMO_ARM64_SHA256:-} ;;
    *) die 'unsupported architecture' ;;
  esac
  [[ $MIHOMO_SHA =~ ^[a-f0-9]{64}$ ]] || die 'Mihomo checksum pin is missing or invalid'
}

verify_services() {
  systemctl is-active --quiet edge-infra-xray-cf.service || die 'Cloudflare Xray service is inactive'
  systemctl is-active --quiet nginx.service || die 'nginx.service is inactive'
}

write_restore_script() {
  cat > "$RESTORE" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
state=/var/lib/edge-infra-cloudflare
source "$state/subscription-transaction.env"
actual=$(sha256sum "$SUBSCRIPTION" | awk '{print $1}')
[[ $actual == "$OLD_SUB_HASH" || $actual == "$NEW_SUB_HASH" ]] || exit 1
actual=$(sha256sum /var/lib/edge-infra-reality/state.env | awk '{print $1}')
[[ $actual == "$OLD_STATE_HASH" || $actual == "$NEW_STATE_HASH" ]] || exit 1
actual=$(sha256sum /usr/local/sbin/edge-infra-reality | awk '{print $1}')
[[ $actual == "$OLD_CLI_HASH" || $actual == "$NEW_CLI_HASH" ]] || exit 1
sub_tmp=$(mktemp "$(dirname -- "$SUBSCRIPTION")/.cf-restore.XXXXXX")
state_tmp=$(mktemp /var/lib/edge-infra-reality/.cf-restore.XXXXXX)
cli_tmp=$(mktemp /usr/local/sbin/.cf-restore.XXXXXX)
trap 'rm -f -- "$sub_tmp" "$state_tmp" "$cli_tmp"' EXIT
cp -p "$BACKUP/subscription.yaml" "$sub_tmp"
cp -p "$BACKUP/reality-state.env" "$state_tmp"
cp -p "$BACKUP/reality-cli" "$cli_tmp"
mv -f "$sub_tmp" "$SUBSCRIPTION"
mv -f "$state_tmp" /var/lib/edge-infra-reality/state.env
mv -f "$cli_tmp" /usr/local/sbin/edge-infra-reality
touch "$state/subscription-rolled-back"
EOF
  chmod 0700 "$RESTORE"
}

publish() {
  [[ ! -e $TRANSACTION ]] || die 'a publication is already pending; accept or roll it back first'
  load_overlay_state
  [[ -f $REALITY_STATE && ! -L $REALITY_STATE ]] || die 'Reality overlay state is missing'
  # Both files are root-owned state written by their installers.
  # shellcheck disable=SC1090,SC1091
  source "$REALITY_STATE"
  local subscription=${SUBSCRIPTION_FILE:-} original_hash=${INSTALLED_SUBSCRIPTION_SHA256:-}
  [[ -f $subscription && ! -L $subscription ]] || die 'subscription file is missing or invalid'
  [[ $(sha256sum "$subscription" | awk '{print $1}') == "$original_hash" ]] \
    || die 'subscription drift detected; inspect it before publishing'
  ! grep -Fq -- '- name: DediOne-Cloudflare' "$subscription" || die 'Cloudflare node already exists'
  [[ -f $STATE/uuid && ! -L $STATE/uuid ]] || die 'UUID state file is missing'
  [[ $(stat -c '%a' "$STATE/uuid") == 600 ]] || die 'UUID state file must be private'
  [[ -f $REALITY_CLI && ! -L $REALITY_CLI && -x $REALITY_CLI ]] || die 'Reality CLI is missing'
  verify_services
  load_versions
  require_command curl
  require_command gzip
  require_command python3

  local tmp candidate new_state
  tmp=$(mktemp -d /tmp/edge-cf-publish.XXXXXX)
  candidate=$tmp/candidate.yaml
  python3 "$GENERATOR" \
    --source "$subscription" \
    --output "$candidate" \
    --hostname "$CF_HOSTNAME" \
    --path "$CF_XHTTP_PATH" \
    --uuid-file "$STATE/uuid" \
    --preferred-ip "${CF_PREFERRED_IP:-}"

  local asset="mihomo-linux-$ARCH-v$MIHOMO_VERSION.gz"
  curl -fsSL --max-time 120 \
    "https://github.com/MetaCubeX/mihomo/releases/download/v$MIHOMO_VERSION/$asset" \
    -o "$tmp/mihomo.gz"
  printf '%s  %s\n' "$MIHOMO_SHA" "$tmp/mihomo.gz" | sha256sum -c --status \
    || die 'Mihomo checksum mismatch'
  gzip -dc "$tmp/mihomo.gz" > "$tmp/mihomo"
  chmod 0700 "$tmp/mihomo"
  "$tmp/mihomo" -t -d "$tmp" -f "$candidate" >"$tmp/mihomo-check.log" 2>&1 \
    || die 'Mihomo rejected the candidate subscription'

  CF_STATE_FILE=$STATE_FILE bash -c 'source "$1"; check_main_chain "$2"' _ \
    "$REALITY_OVERLAY" "$candidate" || die 'Reality verifier rejected the candidate ordering'

  local new_hash old_state_hash new_state_hash old_cli_hash new_cli_hash backup
  new_hash=$(sha256sum "$candidate" | awk '{print $1}')
  old_state_hash=$(sha256sum "$REALITY_STATE" | awk '{print $1}')
  new_state=$tmp/reality-state.env
  awk -v hash="$new_hash" \
    '/^INSTALLED_SUBSCRIPTION_SHA256=/{print "INSTALLED_SUBSCRIPTION_SHA256=" hash; next} {print}' \
    "$REALITY_STATE" > "$new_state"
  new_state_hash=$(sha256sum "$new_state" | awk '{print $1}')
  old_cli_hash=$(sha256sum "$REALITY_CLI" | awk '{print $1}')
  new_cli_hash=$(sha256sum "$REALITY_OVERLAY" | awk '{print $1}')

  install -d -m 0700 "$BACKUPS"
  backup=$(mktemp -d "$BACKUPS/subscription.XXXXXXXX")
  cp -p "$subscription" "$backup/subscription.yaml"
  cp -p "$REALITY_STATE" "$backup/reality-state.env"
  cp -p "$REALITY_CLI" "$backup/reality-cli"
  TIMER=edge-infra-cf-subscription-rollback-$(date -u +%Y%m%dT%H%M%SZ)-$$
  {
    printf 'SUBSCRIPTION=%q\n' "$subscription"
    printf 'BACKUP=%q\n' "$backup"
    printf 'TIMER=%q\n' "$TIMER"
    printf 'OLD_SUB_HASH=%q\n' "$original_hash"
    printf 'NEW_SUB_HASH=%q\n' "$new_hash"
    printf 'OLD_STATE_HASH=%q\n' "$old_state_hash"
    printf 'NEW_STATE_HASH=%q\n' "$new_state_hash"
    printf 'OLD_CLI_HASH=%q\n' "$old_cli_hash"
    printf 'NEW_CLI_HASH=%q\n' "$new_cli_hash"
  } > "$TRANSACTION"
  chmod 0600 "$TRANSACTION"
  write_restore_script
  if ! systemd-run --quiet --unit="$TIMER" --on-active=60m \
      --timer-property=AccuracySec=1s /bin/bash "$RESTORE"; then
    rm -f "$TRANSACTION" "$RESTORE"
    die 'failed to arm the subscription rollback timer'
  fi
  systemctl is-active --quiet "$TIMER.timer" || die 'subscription rollback timer is not active'

  local sub_tmp state_tmp cli_tmp
  sub_tmp=$(mktemp "$(dirname -- "$subscription")/.cf-new.XXXXXX")
  state_tmp=$(mktemp /var/lib/edge-infra-reality/.cf-new.XXXXXX)
  cli_tmp=$(mktemp /usr/local/sbin/.cf-new.XXXXXX)
  if ! {
    cp -p "$subscription" "$sub_tmp" &&
    cat "$candidate" > "$sub_tmp" &&
    cp -p "$REALITY_STATE" "$state_tmp" &&
    cat "$new_state" > "$state_tmp" &&
    install -m 0755 "$REALITY_OVERLAY" "$cli_tmp" &&
    mv -f "$cli_tmp" "$REALITY_CLI" &&
    mv -f "$sub_tmp" "$subscription" &&
    mv -f "$state_tmp" "$REALITY_STATE"
  }; then
    "$RESTORE" || die 'publication failed and the rollback also failed; the timer remains armed'
    systemctl stop "$TIMER.timer" >/dev/null 2>&1 || true
    rm -f "$TRANSACTION" "$RESTORE"
    die 'publication failed and the previous subscription was restored'
  fi
  rm -rf -- "$tmp"
  log 'five-node subscription published with DediOne-Cloudflare last'
  log 'automatic rollback is armed for 60 minutes; validate externally, then run accept --yes'
}

accept() {
  [[ -f $TRANSACTION && ! -e $STATE/subscription-rolled-back ]] || die 'no active publication'
  # shellcheck disable=SC1090
  source "$TRANSACTION"
  [[ ${TIMER:-} =~ ^edge-infra-cf-subscription-rollback-[A-Za-z0-9-]+$ ]] || die 'transaction timer is invalid'
  systemctl is-active --quiet "$TIMER.timer" || die 'publication rollback timer is inactive'
  # shellcheck disable=SC2153
  [[ $(sha256sum "$SUBSCRIPTION" | awk '{print $1}') == "$NEW_SUB_HASH" ]] || die 'subscription changed'
  # shellcheck disable=SC2153
  [[ $(sha256sum "$REALITY_STATE" | awk '{print $1}') == "$NEW_STATE_HASH" ]] || die 'Reality state changed'
  # shellcheck disable=SC2153
  [[ $(sha256sum "$REALITY_CLI" | awk '{print $1}') == "$NEW_CLI_HASH" ]] || die 'Reality CLI changed'
  verify_services
  systemctl stop "$TIMER.timer"
  ! systemctl is-active --quiet "$TIMER.service" || die 'automatic rollback is already running'
  [[ ! -e $STATE/subscription-rolled-back ]] || die 'automatic rollback already completed'
  rm -f "$TRANSACTION" "$RESTORE"
  log 'subscription accepted; private backup retained'
}

rollback() {
  [[ -f $TRANSACTION ]] || die 'no active publication'
  # shellcheck disable=SC1090
  source "$TRANSACTION"
  [[ ${TIMER:-} =~ ^edge-infra-cf-subscription-rollback-[A-Za-z0-9-]+$ ]] || die 'transaction timer is invalid'
  systemctl stop "$TIMER.timer" >/dev/null 2>&1 || true
  [[ -x $RESTORE ]] || die 'restore script is missing'
  "$RESTORE" || die 'rollback failed; inspect the transaction and private backup'
  rm -f "$TRANSACTION" "$RESTORE"
  log 'subscription rollback complete'
}

main() {
  require_root
  local command=${1:-}
  [[ ${2:-} == --yes ]] || die 'requires --yes'
  exec 8>/run/lock/edge-infra-reality.lock
  flock -n 8 || die 'another Reality operation is running'
  exec 9>/run/lock/edge-infra-cloudflare.lock
  flock -n 9 || die 'another Cloudflare operation is running'
  case $command in
    publish) publish ;;
    accept) accept ;;
    rollback) rollback ;;
    *) die 'usage: publish-cloudflare-subscription.sh publish|accept|rollback --yes' ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
