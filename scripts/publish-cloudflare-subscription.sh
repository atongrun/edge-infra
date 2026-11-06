#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GENERATOR=$DIR/cloudflare-subscription.py
STATE=/var/lib/edge-infra-cloudflare
REALITY=/var/lib/edge-infra-reality/state.env
REALITY_CLI=/usr/local/sbin/edge-infra-reality
BACKUPS=/var/backups/edge-infra-cloudflare
TIMER=edge-infra-cf-subscription-rollback
die() { printf 'cloudflare-subscription: %s\n' "$*" >&2; exit 1; }
require_root() { (( EUID == 0 )) || die 'root required'; }
publish() {
  [[ ! -e $STATE/subscription-transaction.env && -f $STATE/state.env && -f $REALITY ]] || die 'missing overlay or pending transaction'
  systemctl is-active --quiet edge-infra-cf-ws.service || die 'WS service inactive'
  systemctl is-active --quiet edge-infra-cloudflared.service || die 'Tunnel service inactive'
  # Both state files are root-owned private files written by their installers.
  # shellcheck disable=SC1090,SC1091
  source "$REALITY"
  local subscription=$SUBSCRIPTION_FILE original_hash=$INSTALLED_SUBSCRIPTION_SHA256
  # shellcheck disable=SC1090,SC1091
  source "$STATE/state.env"
  [[ -f $subscription && ! -L $subscription ]] || die 'invalid subscription file'
  [[ $(sha256sum "$subscription" | awk '{print $1}') == "$original_hash" ]] || die 'subscription drift detected'
  [[ $(grep -c '^INSTALLED_SUBSCRIPTION_SHA256=' "$REALITY") == 1 ]] || die 'unexpected Reality state'
  local tmp candidate backup old_state_hash new_hash new_state_hash old_cli_hash new_cli_hash
  tmp=$(mktemp -d /tmp/edge-cf-publish.XXXXXX)
  candidate=$tmp/candidate.yaml
  python3 "$GENERATOR" --source "$subscription" --output "$candidate" --hostname "$CF_HOSTNAME" --path "$CF_WS_PATH" --uuid-file "$STATE/uuid"
  curl -fsSL --max-time 120 https://github.com/MetaCubeX/mihomo/releases/download/v1.19.32/mihomo-linux-amd64-v1.19.32.gz -o "$tmp/mihomo.gz"
  printf '%s  %s\n' 8451100836c9eda194331c2babfad490b2faf30cebc1a04b0e76fd8ac2d35d10 "$tmp/mihomo.gz" | sha256sum -c --status || die 'Mihomo checksum mismatch'
  gzip -dc "$tmp/mihomo.gz" > "$tmp/mihomo"; chmod 700 "$tmp/mihomo"
  "$tmp/mihomo" -t -d "$tmp" -f "$candidate" > "$STATE/mihomo-check.log" 2>&1 || die 'Mihomo rejected candidate'
  [[ -f $REALITY_CLI && ! -L $REALITY_CLI ]] || die 'Reality CLI is missing or unsupported'
  bash -n "$DIR/reality-overlay.sh"
  bash -c 'source "$1"; check_main_chain "$2"' _ "$DIR/reality-overlay.sh" "$candidate" || die 'Reality verifier rejected candidate'
  new_hash=$(sha256sum "$candidate" | awk '{print $1}')
  old_state_hash=$(sha256sum "$REALITY" | awk '{print $1}')
  awk -v hash="$new_hash" '/^INSTALLED_SUBSCRIPTION_SHA256=/{print "INSTALLED_SUBSCRIPTION_SHA256=" hash; next} {print}' "$REALITY" > "$tmp/new-state"
  new_state_hash=$(sha256sum "$tmp/new-state" | awk '{print $1}')
  old_cli_hash=$(sha256sum "$REALITY_CLI" | awk '{print $1}')
  new_cli_hash=$(sha256sum "$DIR/reality-overlay.sh" | awk '{print $1}')
  install -d -m 0700 "$BACKUPS"
  backup=$(mktemp -d "$BACKUPS/subscription.XXXXXXXX")
  cp -p "$subscription" "$backup/subscription.yaml"
  cp -p "$REALITY" "$backup/reality-state.env"
  cp -p "$REALITY_CLI" "$backup/reality-cli"
  {
    printf 'SUBSCRIPTION=%q\nBACKUP=%q\nOLD_SUB_HASH=%q\nNEW_SUB_HASH=%q\nOLD_STATE_HASH=%q\nNEW_STATE_HASH=%q\nOLD_CLI_HASH=%q\nNEW_CLI_HASH=%q\n' "$subscription" "$backup" "$original_hash" "$new_hash" "$old_state_hash" "$new_state_hash" "$old_cli_hash" "$new_cli_hash"
  } > "$STATE/subscription-transaction.env"
  cat > "$STATE/restore-subscription.sh" <<'EOF'
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
  chmod 0700 "$STATE/restore-subscription.sh"
  systemd-run --quiet --unit="$TIMER" --on-active=60m --timer-property=AccuracySec=1s /bin/bash "$STATE/restore-subscription.sh" || die 'failed to arm subscription rollback'
  systemctl is-active --quiet "$TIMER.timer" || die 'subscription timer inactive'
  local sub_tmp state_tmp cli_tmp
  sub_tmp=$(mktemp "$(dirname -- "$subscription")/.cf-new.XXXXXX")
  state_tmp=$(mktemp /var/lib/edge-infra-reality/.cf-new.XXXXXX)
  cli_tmp=$(mktemp /usr/local/sbin/.cf-new.XXXXXX)
  if ! { cp -p "$subscription" "$sub_tmp" && cat "$candidate" > "$sub_tmp" && cp -p "$REALITY" "$state_tmp" && cat "$tmp/new-state" > "$state_tmp" && install -m 0755 "$DIR/reality-overlay.sh" "$cli_tmp" && mv -f "$cli_tmp" "$REALITY_CLI" && mv -f "$sub_tmp" "$subscription" && mv -f "$state_tmp" "$REALITY"; }; then
    "$STATE/restore-subscription.sh" || die 'publication failed and rollback failed; timer remains armed'
    systemctl stop "$TIMER.timer" || true
    die 'publication failed and was restored'
  fi
  rm -rf "$tmp"
  echo 'five-node subscription published; automatic rollback in 60 minutes unless accepted'
}
# Values used below come from the root-owned transaction file.
# shellcheck disable=SC2153
accept() {
  [[ -f $STATE/subscription-transaction.env && ! -e $STATE/subscription-rolled-back ]] || die 'no active publication'
  # shellcheck disable=SC1090,SC1091
  source "$STATE/subscription-transaction.env"
  systemctl is-active --quiet "$TIMER.timer" || die 'publication timer inactive'
  [[ $(sha256sum "$SUBSCRIPTION" | awk '{print $1}') == "$NEW_SUB_HASH" ]] || die 'subscription changed'
  [[ $(sha256sum "$REALITY" | awk '{print $1}') == "$NEW_STATE_HASH" ]] || die 'Reality state changed'
  [[ $(sha256sum "$REALITY_CLI" | awk '{print $1}') == "$NEW_CLI_HASH" ]] || die 'Reality CLI changed'
  systemctl is-active --quiet edge-infra-cf-ws.service || die 'WS service inactive'
  systemctl is-active --quiet edge-infra-cloudflared.service || die 'Tunnel service inactive'
  systemctl stop "$TIMER.timer"
  ! systemctl is-active --quiet "$TIMER.service" || die 'rollback already running'
  [[ ! -e $STATE/subscription-rolled-back ]] || die 'rollback already completed'
  rm -f "$STATE/subscription-transaction.env" "$STATE/restore-subscription.sh"
  echo 'subscription accepted; private backup retained'
}
main() {
  require_root
  [[ ${2:-} == --yes ]] || die 'requires --yes'
  exec 8>/run/lock/edge-infra-reality.lock; flock -n 8 || die 'Reality operation already running'
  exec 9>/run/lock/edge-infra-cloudflare.lock; flock -n 9 || die 'Cloudflare operation already running'
  case ${1:-} in publish) publish;; accept) accept;; *) die 'usage: publish-cloudflare-subscription.sh publish|accept --yes';; esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
