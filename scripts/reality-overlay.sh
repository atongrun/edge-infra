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

# Resolve the active baseline unit used by either the repo installer or the
# hand-configured layout. Callers use the returned name for snapshots and
# diagnostics instead of assuming one layout.
resolve_baseline_unit() {
  local primary=$1 alt=$2
  if systemctl is-active --quiet "$primary" 2>/dev/null; then
    printf '%s\n' "$primary"
  elif systemctl is-active --quiet "$alt" 2>/dev/null; then
    printf '%s\n' "$alt"
  else
    return 1
  fi
}

# A baseline proxy service may be named edge-infra-hy2.service (repo installer)
# or sing-box.service (hand-configured layout). Accept either.
baseline_service_active() {
  local primary=$1 alt=$2
  systemctl is-active --quiet "$primary" 2>/dev/null && return 0
  systemctl is-active --quiet "$alt" 2>/dev/null && return 0
  return 1
}

# UFW is optional. The overlay only adds/checks a rule when UFW is active.
ufw_is_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

usage() {
  cat <<'EOF'
Usage:
  reality-overlay.sh preflight --config FILE
  reality-overlay.sh install   --config FILE --yes
  reality-overlay.sh status
  reality-overlay.sh verify
  reality-overlay.sh simplify --yes
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
    state_value BASELINE_HY2_UNIT "$BASELINE_HY2_UNIT"
    state_value BASELINE_TROJAN_UNIT "$BASELINE_TROJAN_UNIT"
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
  if ! grep -q '^- name: 主链路$' "$SUBSCRIPTION_FILE"; then
    grep -q '^- name: PROXY$' "$SUBSCRIPTION_FILE" || die 'subscription group PROXY not found'
    grep -q '^- name: Proxies$' "$SUBSCRIPTION_FILE" || die 'subscription group Proxies not found'
    grep -q '^- name: OpenAI$' "$SUBSCRIPTION_FILE" || die 'subscription group OpenAI not found'
  fi
  ! grep -Fq "name: $NODE_NAME" "$SUBSCRIPTION_FILE" || die "$NODE_NAME already exists in subscription"
}

preflight() {
  require_root
  [[ -n $CONFIG_FILE ]] || die '--config is required'
  load_config
  for command in flock grep jq openssl sha256sum ss stat systemctl timeout; do require_command "$command"; done
  [[ -x $SING_BOX_BIN ]] || die "sing-box binary is missing or not executable: $SING_BOX_BIN"
  [[ ! -e $STATE_FILE ]] || die 'Reality overlay state already exists'
  [[ ! -e $REALITY_CONFIG ]] || die "$REALITY_CONFIG already exists"
  [[ ! -e $UNIT_PATH ]] || die "$UNIT_PATH already exists"
  [[ $(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true) == not-found ]] || die "$UNIT_NAME is already registered"
  ! port_in_use "$REALITY_PORT" || die "TCP $REALITY_PORT is already in use"
  BASELINE_HY2_UNIT=$(resolve_baseline_unit edge-infra-hy2.service sing-box.service) || die 'baseline HY2 service is not active (neither edge-infra-hy2.service nor sing-box.service)'
  BASELINE_TROJAN_UNIT=$(resolve_baseline_unit edge-infra-trojan.service sing-box-trojan.service) || die 'baseline Trojan service is not active (neither edge-infra-trojan.service nor sing-box-trojan.service)'
  systemctl is-active --quiet nginx.service || die 'baseline nginx.service is not active'
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

check_main_chain() {
  local file=$1 actual_order expected_order
  [[ $(grep -c '^- name: 主链路$' "$file") == 1 ]] || die 'main chain group must appear exactly once'
  ! grep -Eq '^- name: (PROXY|Proxies|OpenAI)$' "$file" || die 'legacy nested groups remain'
  ! grep -Eq '^-[^#]*,(PROXY|Proxies|OpenAI)(,|$)' "$file" || die 'legacy rule targets remain'

  actual_order=$(awk '
    $0 == "- name: 主链路" {in_group=1; next}
    in_group && /^[A-Za-z0-9_-]+:$/ {in_group=0}
    in_group && /^  - / {sub(/^  - /, ""); print}
  ' "$file")
  expected_order=$'DediOne-Reality\nDediOne-Trojan\nDediOne-HY2\nDediOne-HY2-Hop'
  [[ $actual_order == "$expected_order" ]] || die 'main chain order must be Reality, Trojan, HY2, HY2-Hop'
}

render_main_chain() {
  local source=$1 output=$2
  awk '
    function print_main_chain() {
      print "proxy-groups:"
      print "- name: 主链路"
      print "  type: fallback"
      print "  proxies:"
      print "  - DediOne-Reality"
      print "  - DediOne-Trojan"
      print "  - DediOne-HY2"
      print "  - DediOne-HY2-Hop"
      print "  url: https://www.gstatic.com/generate_204"
      print "  interval: 60"
      print "  timeout: 5000"
      print "  max-failed-times: 2"
      print "  lazy: false"
      print "  expected-status: 204"
    }
    $0 == "proxy-groups:" {
      print_main_chain()
      in_groups=1
      next
    }
    in_groups && /^[A-Za-z0-9_-]+:$/ {in_groups=0}
    in_groups {next}
    $0 == "rules:" {
      in_groups=0
      in_rules=1
      print
      next
    }
    in_rules && /^[A-Za-z0-9_-]+:$/ {in_rules=0}
    in_rules {sub(/,(PROXY|Proxies|OpenAI)$/, ",主链路")}
    {print}
  ' "$source" > "$output"

  check_main_chain "$output"
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
  render_main_chain "$staged" "$output"
  [[ $(grep -c '^- name: DediOne-Reality$' "$output") == 1 ]] || die 'failed to add exactly one Reality node'
  [[ $(grep -c '^  - DediOne-Reality$' "$output") == 1 ]] || die 'failed to make Reality the main candidate'
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
  command -v ufw >/dev/null 2>&1 && ufw status numbered > "$BACKUP_DIR/ufw-before.txt" 2>&1 || true
  ss -lntup > "$BACKUP_DIR/listeners-before.txt"
  systemctl show "$BASELINE_HY2_UNIT" "$BASELINE_TROJAN_UNIT" nginx.service \
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
  if ufw_is_active; then
    ufw allow "$REALITY_PORT/tcp" comment "$UFW_COMMENT"
    UFW_RULE_ADDED=1
  else
    UFW_RULE_ADDED=0
    warn 'UFW is inactive; no host firewall rule was added for the Reality port'
  fi
  write_state
  systemctl enable --now "$UNIT_NAME"

  chown "$SUBSCRIPTION_UID:$SUBSCRIPTION_GID" "$new_subscription"
  chmod "$SUBSCRIPTION_MODE" "$new_subscription"
  mv -f "$new_subscription" "$SUBSCRIPTION_FILE"
  INSTALLED_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  write_state
  verify_overlay
  INSTALLING=0
  log "installed as the main candidate on TCP $REALITY_PORT with Trojan and HY2 fallbacks"
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
  if ufw_is_active; then
    ufw status | grep -Fq "$UFW_COMMENT" || die 'Reality UFW rule missing'
  fi
  [[ $(grep -c '^- name: DediOne-Reality$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'Reality subscription node missing'
  check_main_chain "$SUBSCRIPTION_FILE"
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$INSTALLED_SUBSCRIPTION_SHA256" ]] || die 'subscription changed after install'
  check_target
  baseline_service_active edge-infra-hy2.service sing-box.service || die 'baseline HY2 service is not active'
  baseline_service_active edge-infra-trojan.service sing-box-trojan.service || die 'baseline Trojan service is not active'
  systemctl is-active --quiet nginx.service || die 'baseline nginx.service is not active'
  log 'verification passed'
}

simplify_groups() {
  require_root
  ((ASSUME_YES == 1)) || die 'simplify requires --yes'
  acquire_lock
  load_state

  local current_hash policy_backup staged
  current_hash=$(sha256_file "$SUBSCRIPTION_FILE")
  [[ $current_hash == "$INSTALLED_SUBSCRIPTION_SHA256" ]] || die 'subscription changed after Reality install; inspect it before simplifying'
  policy_backup=$BACKUP_DIR/subscription-before-main-chain.yaml

  if [[ -f $policy_backup ]]; then
    grep -q '^- name: 主链路$' "$SUBSCRIPTION_FILE" || die 'main-chain backup exists but the live policy is not simplified'
    log 'subscription groups are already simplified'
    return 0
  fi

  staged=$(mktemp "$(dirname -- "$SUBSCRIPTION_FILE")/.main-chain-new.XXXXXX")
  WORK_FILES+=("$staged")
  render_main_chain "$SUBSCRIPTION_FILE" "$staged"
  install -m 0600 "$SUBSCRIPTION_FILE" "$policy_backup"
  chown "$SUBSCRIPTION_UID:$SUBSCRIPTION_GID" "$staged"
  chmod "$SUBSCRIPTION_MODE" "$staged"
  mv -f "$staged" "$SUBSCRIPTION_FILE"
  INSTALLED_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  write_state

  if ! (verify_overlay); then
    install -o "$SUBSCRIPTION_UID" -g "$SUBSCRIPTION_GID" -m "$SUBSCRIPTION_MODE" \
      "$policy_backup" "$SUBSCRIPTION_FILE"
    INSTALLED_SUBSCRIPTION_SHA256=$current_hash
    write_state
    rm -f -- "$policy_backup"
    die 'main-chain verification failed; previous subscription restored'
  fi

  if [[ $0 != "$CLI_PATH" ]]; then
    install -m 0755 "$0" "$CLI_PATH"
  fi
  log 'simplified to one main chain: Reality -> Trojan -> HY2 -> HY2-Hop'
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
  if [[ $UFW_RULE_ADDED == 1 ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -Fq "$UFW_COMMENT"; then
    ufw --force delete allow "$REALITY_PORT/tcp" comment "$UFW_COMMENT"
  fi
  install -o "$SUBSCRIPTION_UID" -g "$SUBSCRIPTION_GID" -m "$SUBSCRIPTION_MODE" \
    "$BACKUP_DIR/subscription.yaml" "$SUBSCRIPTION_FILE"
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$BASELINE_SUBSCRIPTION_SHA256" ]] || die 'subscription rollback hash mismatch'
  rm -f "$UNIT_PATH" "$REALITY_CONFIG"
  systemctl daemon-reload
  ! port_in_use "$REALITY_PORT" || die "TCP $REALITY_PORT remains occupied"
  baseline_service_active edge-infra-hy2.service sing-box.service || die 'baseline HY2 service is not active after rollback'
  baseline_service_active edge-infra-trojan.service sing-box-trojan.service || die 'baseline Trojan service is not active after rollback'
  systemctl is-active --quiet nginx.service || die 'baseline nginx.service is not active after rollback'
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
    simplify) simplify_groups ;;
    rollback) rollback_overlay ;;
    *) die "unknown command: $command" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
