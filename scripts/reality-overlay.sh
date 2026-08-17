#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

STATE_DIR=/var/lib/edge-infra-reality
STATE_FILE=$STATE_DIR/state.env
BACKUP_ROOT=/var/backups/edge-infra-reality
REALITY_CONFIG=/etc/sing-box/reality.json
SING_BOX_BIN=/usr/local/bin/sing-box
UNIT_NAME=sing-box-reality.service
UNIT_PATH=/etc/systemd/system/$UNIT_NAME
CLI_PATH=/usr/local/sbin/edge-infra-reality
UFW_COMMENT=edge-infra-reality
NODE_NAME=DediOne-Reality

CONFIG_FILE=''
ASSUME_YES=0
FORCE=0
INSTALLING=0
WORK_FILES=()

log() { printf '[edge-infra-reality] %s\n' "$*"; }
die() { printf '[edge-infra-reality] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

usage() {
  cat <<'EOF'
Usage:
  reality-overlay.sh preflight --config FILE
  reality-overlay.sh install   --config FILE --yes
  reality-overlay.sh status
  reality-overlay.sh verify
  reality-overlay.sh rollback --yes [--force]
EOF
}

parse_options() {
  while (($#)); do
    case "$1" in
      --config) (($# >= 2)) || die '--config requires a path'; CONFIG_FILE=$2; shift 2 ;;
      --yes) ASSUME_YES=1; shift ;;
      --force) FORCE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

require_root() { ((EUID == 0)) || die 'run as root'; }

load_config() {
  local line key value seen=' '
  [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || die 'config must be a regular non-symlink file'
  REALITY_SERVER=''; REALITY_PORT=''; REALITY_TARGET=''; REALITY_SERVER_NAME=''; SUBSCRIPTION_FILE=''
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die "invalid config line: $line"
    key=${line%%=*}; value=${line#*=}
    [[ $key =~ ^[A-Z0-9_]+$ ]] || die "invalid config key: $key"
    [[ $seen != *" $key "* ]] || die "duplicate config key: $key"
    seen+="$key "
    case "$key" in
      REALITY_SERVER) REALITY_SERVER=$value ;;
      REALITY_PORT) REALITY_PORT=$value ;;
      REALITY_TARGET) REALITY_TARGET=$value ;;
      REALITY_SERVER_NAME) REALITY_SERVER_NAME=$value ;;
      SUBSCRIPTION_FILE) SUBSCRIPTION_FILE=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"
  valid_domain "$REALITY_SERVER" || die 'REALITY_SERVER must be a valid FQDN'
  valid_domain "$REALITY_TARGET" || die 'REALITY_TARGET must be a valid FQDN'
  valid_domain "$REALITY_SERVER_NAME" || die 'REALITY_SERVER_NAME must be a valid FQDN'
  valid_port "$REALITY_PORT" || die 'REALITY_PORT must be between 1024 and 65535'
  [[ $SUBSCRIPTION_FILE == /* && $SUBSCRIPTION_FILE != *'..'* ]] || die 'SUBSCRIPTION_FILE must be an absolute path without ..'
}

load_state() {
  [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die "Reality overlay is not installed: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

state_value() { printf '%s=%q\n' "$1" "$2"; }

write_state() {
  {
    state_value INSTALL_ID "$INSTALL_ID"
    state_value BACKUP_DIR "$BACKUP_DIR"
    state_value REALITY_SERVER "$REALITY_SERVER"
    state_value REALITY_PORT "$REALITY_PORT"
    state_value REALITY_TARGET "$REALITY_TARGET"
    state_value REALITY_SERVER_NAME "$REALITY_SERVER_NAME"
    state_value SUBSCRIPTION_FILE "$SUBSCRIPTION_FILE"
    state_value SUBSCRIPTION_MODE "$SUBSCRIPTION_MODE"
    state_value SUBSCRIPTION_UID "$SUBSCRIPTION_UID"
    state_value SUBSCRIPTION_GID "$SUBSCRIPTION_GID"
    state_value BASELINE_SUBSCRIPTION_SHA256 "$BASELINE_SUBSCRIPTION_SHA256"
    state_value INSTALLED_SUBSCRIPTION_SHA256 "${INSTALLED_SUBSCRIPTION_SHA256:-}"
    state_value UFW_RULE_ADDED "${UFW_RULE_ADDED:-0}"
  } > "$STATE_FILE.tmp"
  chmod 0600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

acquire_lock() {
  exec 9>/run/lock/edge-infra-reality.lock
  flock -n 9 || die 'another Reality overlay operation is running'
}

port_in_use() {
  ss -H -lnt | awk -v target="$1" '{p=$4; sub(/^.*:/,"",p); if (p == target) found=1} END {exit found ? 0 : 1}'
}

wait_for_listener() {
  local attempt
  for attempt in {1..20}; do
    if ss -H -lntp | grep -Eq ":${REALITY_PORT}[[:space:]].*sing-box"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

check_target() {
  local output
  output=$(timeout 15 openssl s_client -connect "$REALITY_TARGET:443" -servername "$REALITY_SERVER_NAME" \
    -verify_hostname "$REALITY_SERVER_NAME" -verify_return_error -tls1_3 -alpn h2 </dev/null 2>&1) \
    || die 'Reality target TLS handshake failed'
  grep -Fq 'New, TLSv1.3' <<<"$output" || die 'Reality target did not negotiate TLS 1.3'
  grep -Fq 'ALPN protocol: h2' <<<"$output" || die 'Reality target did not negotiate h2'
  grep -Fq 'Verify return code: 0 (ok)' <<<"$output" || die 'Reality target certificate verification failed'
}

check_subscription_contract() {
  [[ -f $SUBSCRIPTION_FILE && ! -L $SUBSCRIPTION_FILE ]] || die 'subscription must be a regular non-symlink file'
  [[ $(grep -c '^proxies:$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'subscription must contain exactly one proxies section'
  [[ $(grep -c '^proxy-groups:$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'subscription must contain exactly one proxy-groups section'
  grep -q '^- name: Proxies$' "$SUBSCRIPTION_FILE" || die 'subscription group Proxies not found'
  grep -q '^- name: OpenAI$' "$SUBSCRIPTION_FILE" || die 'subscription group OpenAI not found'
  ! grep -Fq "name: $NODE_NAME" "$SUBSCRIPTION_FILE" || die "$NODE_NAME already exists in subscription"
}

preflight() {
  require_root
  [[ -n $CONFIG_FILE ]] || die '--config is required'
  load_config
  for command in flock grep jq openssl sha256sum ss stat systemctl timeout ufw; do require_command "$command"; done
  [[ -x $SING_BOX_BIN ]] || die "sing-box binary is missing or not executable: $SING_BOX_BIN"
  [[ ! -e $STATE_FILE ]] || die 'Reality overlay state already exists'
  [[ ! -e $REALITY_CONFIG ]] || die "$REALITY_CONFIG already exists"
  [[ ! -e $UNIT_PATH ]] || die "$UNIT_PATH already exists"
  [[ $(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true) == not-found ]] || die "$UNIT_NAME is already registered"
  ! port_in_use "$REALITY_PORT" || die "TCP $REALITY_PORT is already in use"
  systemctl is-active --quiet sing-box.service || die 'baseline sing-box.service is not active'
  systemctl is-active --quiet sing-box-trojan.service || die 'baseline sing-box-trojan.service is not active'
  systemctl is-active --quiet nginx.service || die 'baseline nginx.service is not active'
  ufw status | grep -q '^Status: active' || die 'UFW must already be active'
  check_subscription_contract
  check_target
  log "preflight passed: TCP $REALITY_PORT, target $REALITY_TARGET, subscription contract"
}

render_reality_config() {
  jq -n \
    --arg uuid "$REALITY_UUID" \
    --arg target "$REALITY_TARGET" \
    --arg server_name "$REALITY_SERVER_NAME" \
    --arg private_key "$REALITY_PRIVATE_KEY" \
    --arg short_id "$REALITY_SHORT_ID" \
    --argjson port "$REALITY_PORT" \
    '{log:{level:"info",timestamp:true},inbounds:[{type:"vless",tag:"reality-in",listen:"0.0.0.0",listen_port:$port,users:[{name:"personal",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$server_name,reality:{enabled:true,handshake:{server:$target,server_port:443},private_key:$private_key,short_id:[$short_id]}}}],outbounds:[{type:"direct",tag:"direct"}]}'
}

render_client_node() {
  cat <<EOF
  - name: $NODE_NAME
    type: vless
    server: $REALITY_SERVER
    port: $REALITY_PORT
    uuid: $REALITY_UUID
    network: tcp
    udp: true
    tls: true
    servername: $REALITY_SERVER_NAME
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: $REALITY_PUBLIC_KEY
      short-id: $REALITY_SHORT_ID
EOF
}

render_subscription() {
  local source=$1 node=$2 output=$3 staged
  staged=$(mktemp "$(dirname -- "$source")/.reality-stage.XXXXXX")
  WORK_FILES+=("$staged")
  awk -v node_file="$node" '
    $0 == "proxy-groups:" {
      while ((getline line < node_file) > 0) print line
      close(node_file)
    }
    {print}
  ' "$source" > "$staged"
  awk '
    /^- name: (Proxies|OpenAI)$/ {target=1; added=0; print; next}
    /^- name:/ {target=0}
    target && !added && $0 == "  - PROXY" {print; print "  - DediOne-Reality"; added=1; next}
    {print}
  ' "$staged" > "$output"
  [[ $(grep -c '^  - name: DediOne-Reality$' "$output") == 1 ]] || die 'failed to add exactly one Reality node'
  [[ $(grep -c '^  - DediOne-Reality$' "$output") == 2 ]] || die 'failed to add Reality to Proxies and OpenAI groups'
}

rollback_partial() {
  set +e
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
  if [[ ${UFW_RULE_ADDED:-0} == 1 ]]; then
    ufw --force delete allow "$REALITY_PORT/tcp" comment "$UFW_COMMENT" >/dev/null 2>&1
  fi
  if [[ -n ${BACKUP_DIR:-} && -f ${BACKUP_DIR:-}/subscription.yaml && -n ${SUBSCRIPTION_FILE:-} ]]; then
    install -o "${SUBSCRIPTION_UID:-0}" -g "${SUBSCRIPTION_GID:-0}" -m "${SUBSCRIPTION_MODE:-600}" \
      "$BACKUP_DIR/subscription.yaml" "$SUBSCRIPTION_FILE"
  fi
  rm -f "$UNIT_PATH" "$REALITY_CONFIG"
  systemctl daemon-reload >/dev/null 2>&1
  rm -f "$STATE_FILE" "$CLI_PATH"
  rmdir "$STATE_DIR" 2>/dev/null || true
  set -e
}

cleanup_work() {
  local file
  for file in "${WORK_FILES[@]:-}"; do [[ -n $file ]] && rm -f -- "$file"; done
}

finish() {
  local status=$?
  trap - EXIT
  if ((INSTALLING)); then
    rollback_partial
  fi
  cleanup_work
  exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

install_overlay() {
  ((ASSUME_YES == 1)) || die 'install requires --yes'
  preflight
  [[ -f $PROJECT_ROOT/templates/systemd/edge-infra-reality.service ]] || die 'run install from the reviewed edge-infra repository'
  acquire_lock
  INSTALLING=1

  INSTALL_ID=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP_DIR=$BACKUP_ROOT/$INSTALL_ID
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  SUBSCRIPTION_MODE=$(stat -c '%a' "$SUBSCRIPTION_FILE")
  SUBSCRIPTION_UID=$(stat -c '%u' "$SUBSCRIPTION_FILE")
  SUBSCRIPTION_GID=$(stat -c '%g' "$SUBSCRIPTION_FILE")
  BASELINE_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  UFW_RULE_ADDED=0
  install -m 0600 "$SUBSCRIPTION_FILE" "$BACKUP_DIR/subscription.yaml"
  ufw status numbered > "$BACKUP_DIR/ufw-before.txt"
  ss -lntup > "$BACKUP_DIR/listeners-before.txt"
  systemctl show sing-box.service sing-box-trojan.service nginx.service \
    -p Id -p ActiveState -p NRestarts > "$BACKUP_DIR/services-before.txt"
  write_state

  REALITY_UUID=$("$SING_BOX_BIN" generate uuid)
  local keys node_file new_subscription
  keys=$("$SING_BOX_BIN" generate reality-keypair)
  REALITY_PRIVATE_KEY=$(awk '$1 == "PrivateKey:" {print $2}' <<<"$keys")
  REALITY_PUBLIC_KEY=$(awk '$1 == "PublicKey:" {print $2}' <<<"$keys")
  REALITY_SHORT_ID=$(openssl rand -hex 8)
  [[ -n $REALITY_PRIVATE_KEY && -n $REALITY_PUBLIC_KEY ]] || die 'failed to generate Reality keypair'

  node_file=$(mktemp "$STATE_DIR/node.XXXXXX")
  new_subscription=$(mktemp "$(dirname -- "$SUBSCRIPTION_FILE")/.reality-new.XXXXXX")
  WORK_FILES+=("$node_file" "$new_subscription")
  render_reality_config > "$STATE_DIR/reality.json.new"
  WORK_FILES+=("$STATE_DIR/reality.json.new")
  chmod 0600 "$STATE_DIR/reality.json.new"
  "$SING_BOX_BIN" check -c "$STATE_DIR/reality.json.new"
  render_client_node > "$node_file"
  render_subscription "$SUBSCRIPTION_FILE" "$node_file" "$new_subscription"

  install -m 0600 "$STATE_DIR/reality.json.new" "$REALITY_CONFIG"
  install -m 0644 "$PROJECT_ROOT/templates/systemd/edge-infra-reality.service" "$UNIT_PATH"
  install -m 0755 "$0" "$CLI_PATH"
  systemctl daemon-reload
  ufw allow "$REALITY_PORT/tcp" comment "$UFW_COMMENT"
  UFW_RULE_ADDED=1
  write_state
  systemctl enable --now "$UNIT_NAME"

  chown "$SUBSCRIPTION_UID:$SUBSCRIPTION_GID" "$new_subscription"
  chmod "$SUBSCRIPTION_MODE" "$new_subscription"
  mv -f "$new_subscription" "$SUBSCRIPTION_FILE"
  INSTALLED_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  write_state
  verify_overlay
  INSTALLING=0
  log "installed as a candidate on TCP $REALITY_PORT; existing default groups remain first"
}

status_overlay() {
  require_root
  load_state
  printf '%-24s %s\n' \
    SERVICE "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)" \
    ENABLED "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)" \
    TCP_PORT "$REALITY_PORT" \
    TARGET "$REALITY_TARGET" \
    SERVER_NAME "$REALITY_SERVER_NAME" \
    SUBSCRIPTION "$SUBSCRIPTION_FILE"
}

verify_overlay() {
  require_root
  load_state
  [[ -f $REALITY_CONFIG && ! -L $REALITY_CONFIG ]] || die 'Reality config missing or invalid'
  "$SING_BOX_BIN" check -c "$REALITY_CONFIG" >/dev/null
  systemctl is-active --quiet "$UNIT_NAME" || die 'Reality service is not active'
  systemctl is-enabled --quiet "$UNIT_NAME" || die 'Reality service is not enabled'
  wait_for_listener || die "sing-box is not listening on TCP $REALITY_PORT"
  ufw status | grep -Fq "$UFW_COMMENT" || die 'Reality UFW rule missing'
  [[ $(grep -c '^  - name: DediOne-Reality$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'Reality subscription node missing'
  [[ $(grep -c '^  - DediOne-Reality$' "$SUBSCRIPTION_FILE") == 2 ]] || die 'Reality selector entries missing'
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$INSTALLED_SUBSCRIPTION_SHA256" ]] || die 'subscription changed after install'
  check_target
  for unit in sing-box.service sing-box-trojan.service nginx.service; do
    systemctl is-active --quiet "$unit" || die "baseline service is not active: $unit"
  done
  log 'verification passed'
}

rollback_overlay() {
  require_root
  ((ASSUME_YES == 1)) || die 'rollback requires --yes'
  acquire_lock
  load_state
  if [[ -f $SUBSCRIPTION_FILE && $(sha256_file "$SUBSCRIPTION_FILE") != "$INSTALLED_SUBSCRIPTION_SHA256" && $FORCE == 0 ]]; then
    die 'subscription changed after Reality install; inspect it or use --force intentionally'
  fi
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  if [[ $UFW_RULE_ADDED == 1 ]] && ufw status | grep -Fq "$UFW_COMMENT"; then
    ufw --force delete allow "$REALITY_PORT/tcp" comment "$UFW_COMMENT"
  fi
  install -o "$SUBSCRIPTION_UID" -g "$SUBSCRIPTION_GID" -m "$SUBSCRIPTION_MODE" \
    "$BACKUP_DIR/subscription.yaml" "$SUBSCRIPTION_FILE"
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$BASELINE_SUBSCRIPTION_SHA256" ]] || die 'subscription rollback hash mismatch'
  rm -f "$UNIT_PATH" "$REALITY_CONFIG"
  systemctl daemon-reload
  ! port_in_use "$REALITY_PORT" || die "TCP $REALITY_PORT remains occupied"
  for unit in sing-box.service sing-box-trojan.service nginx.service; do
    systemctl is-active --quiet "$unit" || die "baseline service is not active after rollback: $unit"
  done
  rm -f "$STATE_FILE" "$CLI_PATH"
  rmdir "$STATE_DIR" 2>/dev/null || true
  log "rollback complete; backup retained at $BACKUP_DIR"
}

main() {
  (($# >= 1)) || { usage; exit 1; }
  local command=$1
  shift
  parse_options "$@"
  case "$command" in
    preflight) preflight ;;
    install) install_overlay ;;
    status) status_overlay ;;
    verify) verify_overlay ;;
    rollback) rollback_overlay ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
