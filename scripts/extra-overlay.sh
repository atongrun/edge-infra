#!/usr/bin/env bash
# Independent AnyTLS (TCP) + TUIC v5 (UDP) overlay.
#
# Runs as its own sing-box service (sing-box-extra.service, /etc/sing-box/extra.json)
# so the baseline HY2, Trojan and Reality services are never restarted. Both
# inbounds reuse the existing edge certificate by path. The two client nodes are
# appended to the END of the 主链路 fallback group, so the existing priority
# Reality -> Trojan -> HY2 -> HY2-Hop is unchanged.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

STATE_DIR=${EDGE_INFRA_EXTRA_STATE_DIR:-/var/lib/edge-infra-extra}
STATE_FILE=$STATE_DIR/state.env
BACKUP_ROOT=/var/backups/edge-infra-extra
EXTRA_CONFIG=/etc/sing-box/extra.json
SING_BOX_BIN=/usr/local/bin/sing-box
UNIT_NAME=sing-box-extra.service
UNIT_PATH=/etc/systemd/system/$UNIT_NAME
CLI_PATH=/usr/local/sbin/edge-infra-extra
RENEW_HOOK=/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box-extra
REALITY_STATE=${EDGE_INFRA_REALITY_STATE:-/var/lib/edge-infra-reality/state.env}
UFW_COMMENT_ANYTLS=edge-infra-anytls
UFW_COMMENT_TUIC=edge-infra-tuic
ANYTLS_NODE=DediOne-AnyTLS
TUIC_NODE=DediOne-TUIC
BASE_ORDER=$'DediOne-Reality\nDediOne-Trojan\nDediOne-HY2\nDediOne-HY2-Hop'

CONFIG_FILE=''
ASSUME_YES=0
FORCE=0
INSTALLING=0
WORK_FILES=()

log() { printf '[edge-infra-extra] %s\n' "$*"; }
warn() { printf '[edge-infra-extra] WARN: %s\n' "$*" >&2; }
die() { printf '[edge-infra-extra] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
require_root() { ((EUID == 0)) || die 'run as root'; }
ufw_is_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

usage() {
  cat <<'EOF'
Usage:
  extra-overlay.sh preflight --config FILE
  extra-overlay.sh install   --config FILE --yes
  extra-overlay.sh publish --yes
  extra-overlay.sh status
  extra-overlay.sh verify
  extra-overlay.sh rollback --yes [--force]
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

load_config() {
  local line key value seen=' '
  [[ -f $CONFIG_FILE && ! -L $CONFIG_FILE ]] || die 'config must be a regular non-symlink file'
  EXTRA_SERVER=''; EXTRA_SERVER_NAME=''; CERT_PATH=''; KEY_PATH=''; ANYTLS_PORT=''; TUIC_PORT=''; SUBSCRIPTION_FILE=''
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die "invalid config line: $line"
    key=${line%%=*}; value=${line#*=}
    [[ $key =~ ^[A-Z0-9_]+$ ]] || die "invalid config key: $key"
    [[ $seen != *" $key "* ]] || die "duplicate config key: $key"
    seen+="$key "
    case "$key" in
      EXTRA_SERVER) EXTRA_SERVER=$value ;;
      EXTRA_SERVER_NAME) EXTRA_SERVER_NAME=$value ;;
      CERT_PATH) CERT_PATH=$value ;;
      KEY_PATH) KEY_PATH=$value ;;
      ANYTLS_PORT) ANYTLS_PORT=$value ;;
      TUIC_PORT) TUIC_PORT=$value ;;
      SUBSCRIPTION_FILE) SUBSCRIPTION_FILE=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"
  valid_domain "$EXTRA_SERVER" || die 'EXTRA_SERVER must be a valid FQDN'
  valid_domain "$EXTRA_SERVER_NAME" || die 'EXTRA_SERVER_NAME must be a valid FQDN'
  valid_port "$ANYTLS_PORT" || die 'ANYTLS_PORT must be between 1024 and 65535'
  valid_port "$TUIC_PORT" || die 'TUIC_PORT must be between 1024 and 65535'
  local path
  for path in "$CERT_PATH" "$KEY_PATH" "$SUBSCRIPTION_FILE"; do
    [[ $path == /* && $path != *'..'* ]] || die 'paths must be absolute without ..'
  done
}

load_state() {
  [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die "extra overlay is not installed: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

state_value() { printf '%s=%q\n' "$1" "$2"; }

write_state() {
  {
    state_value INSTALL_ID "$INSTALL_ID"
    state_value BACKUP_DIR "$BACKUP_DIR"
    state_value EXTRA_SERVER "$EXTRA_SERVER"
    state_value EXTRA_SERVER_NAME "$EXTRA_SERVER_NAME"
    state_value CERT_PATH "$CERT_PATH"
    state_value KEY_PATH "$KEY_PATH"
    state_value ANYTLS_PORT "$ANYTLS_PORT"
    state_value TUIC_PORT "$TUIC_PORT"
    state_value SUBSCRIPTION_FILE "$SUBSCRIPTION_FILE"
    state_value SUBSCRIPTION_MODE "$SUBSCRIPTION_MODE"
    state_value SUBSCRIPTION_UID "$SUBSCRIPTION_UID"
    state_value SUBSCRIPTION_GID "$SUBSCRIPTION_GID"
    state_value BASELINE_SUBSCRIPTION_SHA256 "$BASELINE_SUBSCRIPTION_SHA256"
    state_value INSTALLED_SUBSCRIPTION_SHA256 "${INSTALLED_SUBSCRIPTION_SHA256:-}"
    state_value UFW_ANYTLS_ADDED "${UFW_ANYTLS_ADDED:-0}"
    state_value UFW_TUIC_ADDED "${UFW_TUIC_ADDED:-0}"
  } > "$STATE_FILE.tmp"
  chmod 0600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

acquire_lock() {
  exec 9>/run/lock/edge-infra-extra.lock
  flock -n 9 || die 'another extra overlay operation is running'
}

tcp_port_in_use() { ss -H -lnt | awk -v t="$1" '{p=$4; sub(/^.*:/,"",p); if (p == t) f=1} END {exit f ? 0 : 1}'; }
udp_port_in_use() { ss -H -lnu | awk -v t="$1" '{p=$4; sub(/^.*:/,"",p); if (p == t) f=1} END {exit f ? 0 : 1}'; }

wait_for_listeners() {
  for _ in {1..20}; do
    if ss -H -lntp | grep -Eq ":${ANYTLS_PORT}[[:space:]].*sing-box" \
      && ss -H -lnup | grep -Eq ":${TUIC_PORT}[[:space:]].*sing-box"; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

reality_installed_hash() {
  [[ -f $REALITY_STATE && ! -L $REALITY_STATE ]] || return 1
  awk -F= '$1 == "INSTALLED_SUBSCRIPTION_SHA256" {v=substr($0, index($0, "=") + 1); gsub(/["'\'']/, "", v); print v; exit}' "$REALITY_STATE"
}

main_chain_order() {
  awk '
    $0 == "- name: 主链路" {in_group=1; next}
    in_group && /^[A-Za-z0-9_-]+:$/ {in_group=0}
    in_group && /^- name: / {in_group=0}
    in_group && /^  - / {sub(/^  - /, ""); print}
  ' "$1"
}

check_extra_subscription() {
  local file=$1
  [[ $(grep -c '^- name: 主链路$' "$file") == 1 ]] || die 'main chain group must appear exactly once'
  [[ $(grep -c "^- name: $ANYTLS_NODE\$" "$file") == 1 ]] || die "$ANYTLS_NODE must appear exactly once"
  [[ $(grep -c "^- name: $TUIC_NODE\$" "$file") == 1 ]] || die "$TUIC_NODE must appear exactly once"
  [[ $(main_chain_order "$file") == "$BASE_ORDER"$'\n'"$ANYTLS_NODE"$'\n'"$TUIC_NODE" ]] \
    || die 'main chain order must be Reality, Trojan, HY2, HY2-Hop, AnyTLS, TUIC'
}

check_subscription_contract() {
  [[ -f $SUBSCRIPTION_FILE && ! -L $SUBSCRIPTION_FILE ]] || die 'subscription must be a regular non-symlink file'
  [[ $(grep -c '^proxies:$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'subscription must contain exactly one proxies section'
  [[ $(grep -c '^proxy-groups:$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'subscription must contain exactly one proxy-groups section'
  [[ $(grep -c '^- name: 主链路$' "$SUBSCRIPTION_FILE") == 1 ]] || die 'subscription must already use the single 主链路 group'
  ! grep -Eq "^- name: ($ANYTLS_NODE|$TUIC_NODE)\$" "$SUBSCRIPTION_FILE" || die 'extra nodes already exist in subscription'
  ! grep -q '^- name: DediOne-Cloudflare$' "$SUBSCRIPTION_FILE" || die 'Cloudflare node is published; remove it first'
  [[ $(main_chain_order "$SUBSCRIPTION_FILE") == "$BASE_ORDER" ]] || die 'main chain is not Reality, Trojan, HY2, HY2-Hop'
  local reality_hash
  if reality_hash=$(reality_installed_hash) && [[ -n $reality_hash ]]; then
    [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$reality_hash" ]] \
      || die 'subscription differs from the Reality overlay record; inspect it first'
  fi
}

check_certificate() {
  [[ -r $CERT_PATH && -r $KEY_PATH ]] || die 'certificate or key is not readable'
  openssl x509 -in "$CERT_PATH" -noout -checkend 86400 >/dev/null || die 'certificate expires within 24h'
  openssl x509 -in "$CERT_PATH" -noout -checkhost "$EXTRA_SERVER_NAME" | grep -q 'does match' \
    || die "certificate does not cover $EXTRA_SERVER_NAME"
}

preflight() {
  require_root
  [[ -n $CONFIG_FILE ]] || die '--config is required'
  load_config
  for command in awk flock grep jq openssl sha256sum ss stat systemctl; do require_command "$command"; done
  [[ -x $SING_BOX_BIN ]] || die "sing-box binary is missing: $SING_BOX_BIN"
  [[ ! -e $STATE_FILE ]] || die 'extra overlay state already exists'
  [[ ! -e $EXTRA_CONFIG ]] || die "$EXTRA_CONFIG already exists"
  [[ ! -e $UNIT_PATH ]] || die "$UNIT_PATH already exists"
  [[ $(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true) == not-found ]] || die "$UNIT_NAME is already registered"
  ! tcp_port_in_use "$ANYTLS_PORT" || die "TCP $ANYTLS_PORT is already in use"
  ! udp_port_in_use "$TUIC_PORT" || die "UDP $TUIC_PORT is already in use"
  check_certificate
  check_subscription_contract
  log "preflight passed: AnyTLS TCP $ANYTLS_PORT, TUIC UDP $TUIC_PORT, subscription contract"
}

render_extra_config() {
  jq -n \
    --arg server_name "$EXTRA_SERVER_NAME" \
    --arg cert "$CERT_PATH" \
    --arg key "$KEY_PATH" \
    --arg anytls_password "$ANYTLS_PASSWORD" \
    --arg tuic_uuid "$TUIC_UUID" \
    --arg tuic_password "$TUIC_PASSWORD" \
    --argjson anytls_port "$ANYTLS_PORT" \
    --argjson tuic_port "$TUIC_PORT" \
    '{log:{level:"info",timestamp:true},
      inbounds:[
        {type:"anytls",tag:"anytls-in",listen:"::",listen_port:$anytls_port,
         users:[{name:"personal",password:$anytls_password}],
         tls:{enabled:true,server_name:$server_name,certificate_path:$cert,key_path:$key}},
        {type:"tuic",tag:"tuic-in",listen:"::",listen_port:$tuic_port,
         users:[{name:"personal",uuid:$tuic_uuid,password:$tuic_password}],
         congestion_control:"bbr",zero_rtt_handshake:false,
         tls:{enabled:true,server_name:$server_name,alpn:["h3"],certificate_path:$cert,key_path:$key}}],
      outbounds:[{type:"direct",tag:"direct"}]}'
}

render_client_nodes() {
  cat <<EOF
- name: $ANYTLS_NODE
  type: anytls
  server: $EXTRA_SERVER
  port: $ANYTLS_PORT
  password: $ANYTLS_PASSWORD
  sni: $EXTRA_SERVER_NAME
  skip-cert-verify: false
  client-fingerprint: chrome
  udp: true
- name: $TUIC_NODE
  type: tuic
  server: $EXTRA_SERVER
  port: $TUIC_PORT
  uuid: $TUIC_UUID
  password: $TUIC_PASSWORD
  sni: $EXTRA_SERVER_NAME
  skip-cert-verify: false
  alpn:
  - h3
  congestion-controller: bbr
  udp-relay-mode: native
  reduce-rtt: false
EOF
}

# Insert node definitions just before proxy-groups and append both names after
# DediOne-HY2-Hop inside 主链路. Everything else is copied byte for byte.
render_subscription() {
  local source=$1 node=$2 output=$3
  awk -v node_file="$node" -v a="$ANYTLS_NODE" -v t="$TUIC_NODE" '
    $0 == "proxy-groups:" {
      while ((getline line < node_file) > 0) print line
      close(node_file)
    }
    $0 == "- name: 主链路" {in_group=1; print; next}
    in_group && (/^[A-Za-z0-9_-]+:$/ || /^- name: /) {in_group=0}
    {print}
    in_group && $0 == "  - DediOne-HY2-Hop" {print "  - " a; print "  - " t; done=1}
    END {if (!done) exit 3}
  ' "$source" > "$output" || die 'failed to append extra nodes to 主链路'
  check_extra_subscription "$output"
}

install_renew_hook() {
  local lineage
  lineage=$(dirname -- "$CERT_PATH")
  cat > "$RENEW_HOOK.tmp" <<EOF
#!/bin/sh
set -eu
if [ "\${RENEWED_LINEAGE:-}" = "$lineage" ] && systemctl is-active --quiet $UNIT_NAME; then
  $SING_BOX_BIN check -c $EXTRA_CONFIG
  systemctl restart $UNIT_NAME
fi
EOF
  chmod 0700 "$RENEW_HOOK.tmp"
  mv -f "$RENEW_HOOK.tmp" "$RENEW_HOOK"
}

rollback_partial() {
  set +e
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1
  [[ ${UFW_ANYTLS_ADDED:-0} == 1 ]] && ufw --force delete allow "$ANYTLS_PORT/tcp" comment "$UFW_COMMENT_ANYTLS" >/dev/null 2>&1
  [[ ${UFW_TUIC_ADDED:-0} == 1 ]] && ufw --force delete allow "$TUIC_PORT/udp" comment "$UFW_COMMENT_TUIC" >/dev/null 2>&1
  if [[ -n ${BACKUP_DIR:-} && -f ${BACKUP_DIR:-}/subscription.yaml && -n ${SUBSCRIPTION_FILE:-} ]]; then
    install -o "${SUBSCRIPTION_UID:-0}" -g "${SUBSCRIPTION_GID:-0}" -m "${SUBSCRIPTION_MODE:-600}" \
      "$BACKUP_DIR/subscription.yaml" "$SUBSCRIPTION_FILE"
  fi
  rm -f "$UNIT_PATH" "$EXTRA_CONFIG" "$RENEW_HOOK"
  systemctl daemon-reload >/dev/null 2>&1
  rm -f "$STATE_FILE" "$CLI_PATH"
  rm -rf -- "$STATE_DIR"
  set -e
}

cleanup_work() {
  local file
  for file in "${WORK_FILES[@]:-}"; do
    if [[ -n $file ]]; then rm -f -- "$file"; fi
  done
}

finish() {
  local status=$?
  trap - EXIT
  if ((INSTALLING)); then rollback_partial; fi
  cleanup_work
  exit "$status"
}
trap finish EXIT
trap 'exit 1' INT TERM

install_overlay() {
  ((ASSUME_YES == 1)) || die 'install requires --yes'
  preflight
  [[ -f $PROJECT_ROOT/templates/systemd/edge-infra-extra.service ]] || die 'run install from the reviewed edge-infra repository'
  acquire_lock
  INSTALLING=1

  INSTALL_ID=$(date -u +%Y%m%dT%H%M%SZ)
  BACKUP_DIR=$BACKUP_ROOT/$INSTALL_ID
  install -d -m 0700 "$STATE_DIR" "$BACKUP_DIR"
  SUBSCRIPTION_MODE=$(stat -c '%a' "$SUBSCRIPTION_FILE")
  SUBSCRIPTION_UID=$(stat -c '%u' "$SUBSCRIPTION_FILE")
  SUBSCRIPTION_GID=$(stat -c '%g' "$SUBSCRIPTION_FILE")
  BASELINE_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  UFW_ANYTLS_ADDED=0; UFW_TUIC_ADDED=0
  install -m 0600 "$SUBSCRIPTION_FILE" "$BACKUP_DIR/subscription.yaml"
  if command -v ufw >/dev/null 2>&1; then ufw status numbered > "$BACKUP_DIR/ufw-before.txt" 2>&1 || true; fi
  ss -lntup > "$BACKUP_DIR/listeners-before.txt"
  sha256sum /etc/sing-box/*.json > "$BACKUP_DIR/baseline-configs.sha256" 2>/dev/null || true
  systemctl show sing-box.service sing-box-trojan.service sing-box-reality.service nginx.service \
    -p Id -p ActiveState -p NRestarts -p ExecMainStartTimestamp > "$BACKUP_DIR/services-before.txt" 2>/dev/null || true
  write_state

  ANYTLS_PASSWORD=$(openssl rand -hex 24)
  TUIC_UUID=$("$SING_BOX_BIN" generate uuid)
  TUIC_PASSWORD=$(openssl rand -hex 24)
  [[ -n $ANYTLS_PASSWORD && -n $TUIC_UUID && -n $TUIC_PASSWORD ]] || die 'failed to generate credentials'

  local node_file new_subscription
  node_file=$(mktemp "$STATE_DIR/node.XXXXXX")
  new_subscription=$(mktemp "$(dirname -- "$SUBSCRIPTION_FILE")/.extra-new.XXXXXX")
  WORK_FILES+=("$node_file" "$new_subscription" "$STATE_DIR/extra.json.new")
  render_extra_config > "$STATE_DIR/extra.json.new"
  chmod 0600 "$STATE_DIR/extra.json.new"
  "$SING_BOX_BIN" check -c "$STATE_DIR/extra.json.new"
  render_client_nodes > "$node_file"
  render_subscription "$SUBSCRIPTION_FILE" "$node_file" "$new_subscription"

  install -m 0600 "$STATE_DIR/extra.json.new" "$EXTRA_CONFIG"
  install -m 0644 "$PROJECT_ROOT/templates/systemd/edge-infra-extra.service" "$UNIT_PATH"
  install -m 0755 "$0" "$CLI_PATH"
  install_renew_hook
  systemctl daemon-reload
  if ufw_is_active; then
    ufw allow "$ANYTLS_PORT/tcp" comment "$UFW_COMMENT_ANYTLS"; UFW_ANYTLS_ADDED=1
    ufw allow "$TUIC_PORT/udp" comment "$UFW_COMMENT_TUIC"; UFW_TUIC_ADDED=1
  else
    warn 'UFW is inactive; no host firewall rules were added'
  fi
  write_state
  systemctl enable --now "$UNIT_NAME"
  wait_for_listeners || die 'sing-box-extra is not listening on both ports'

  if [[ ${EXTRA_SKIP_PUBLISH:-0} == 1 ]]; then
    install -m 0600 "$new_subscription" "$STATE_DIR/subscription.candidate.yaml"
    INSTALLED_SUBSCRIPTION_SHA256=$BASELINE_SUBSCRIPTION_SHA256
    write_state
    INSTALLING=0
    log "service installed; candidate subscription staged at $STATE_DIR/subscription.candidate.yaml (not published)"
    return 0
  fi
  publish_candidate "$new_subscription"
  verify_overlay
  INSTALLING=0
  log "installed: AnyTLS TCP $ANYTLS_PORT, TUIC UDP $TUIC_PORT appended to 主链路"
}

publish_candidate() {
  local candidate=$1
  check_extra_subscription "$candidate"
  chown "$SUBSCRIPTION_UID:$SUBSCRIPTION_GID" "$candidate"
  chmod "$SUBSCRIPTION_MODE" "$candidate"
  mv -f "$candidate" "$SUBSCRIPTION_FILE"
  INSTALLED_SUBSCRIPTION_SHA256=$(sha256_file "$SUBSCRIPTION_FILE")
  write_state
}

# Publish a staged candidate after out-of-band end-to-end tests passed.
publish_overlay() {
  require_root
  ((ASSUME_YES == 1)) || die 'publish requires --yes'
  acquire_lock
  load_state
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$BASELINE_SUBSCRIPTION_SHA256" ]] || die 'subscription changed since install'
  local staged
  staged=$(mktemp "$(dirname -- "$SUBSCRIPTION_FILE")/.extra-new.XXXXXX")
  WORK_FILES+=("$staged")
  install -m 0600 "$STATE_DIR/subscription.candidate.yaml" "$staged"
  publish_candidate "$staged"
  rm -f "$STATE_DIR/subscription.candidate.yaml"
  verify_overlay
  log 'published AnyTLS and TUIC nodes'
}

status_overlay() {
  require_root
  load_state
  printf '%-24s %s\n' \
    SERVICE "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)" \
    ENABLED "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)" \
    ANYTLS_TCP_PORT "$ANYTLS_PORT" \
    TUIC_UDP_PORT "$TUIC_PORT" \
    SUBSCRIPTION "$SUBSCRIPTION_FILE"
}

verify_overlay() {
  require_root
  load_state
  [[ -f $EXTRA_CONFIG && ! -L $EXTRA_CONFIG ]] || die 'extra config missing or invalid'
  "$SING_BOX_BIN" check -c "$EXTRA_CONFIG" >/dev/null
  systemctl is-active --quiet "$UNIT_NAME" || die 'extra service is not active'
  systemctl is-enabled --quiet "$UNIT_NAME" || die 'extra service is not enabled'
  wait_for_listeners || die 'sing-box-extra is not listening on both ports'
  if ufw_is_active; then
    ufw status | grep -Fq "$UFW_COMMENT_ANYTLS" || die 'AnyTLS UFW rule missing'
    ufw status | grep -Fq "$UFW_COMMENT_TUIC" || die 'TUIC UFW rule missing'
  fi
  if [[ ! -f $STATE_DIR/subscription.candidate.yaml ]]; then
    check_extra_subscription "$SUBSCRIPTION_FILE"
    [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$INSTALLED_SUBSCRIPTION_SHA256" ]] || die 'subscription changed after install'
  fi
  local unit
  for unit in sing-box.service sing-box-trojan.service sing-box-reality.service nginx.service; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
      systemctl is-active --quiet "$unit" || die "baseline $unit is not active"
    fi
  done
  log 'verification passed'
}

rollback_overlay() {
  require_root
  ((ASSUME_YES == 1)) || die 'rollback requires --yes'
  acquire_lock
  load_state
  if [[ -f $SUBSCRIPTION_FILE && $(sha256_file "$SUBSCRIPTION_FILE") != "$INSTALLED_SUBSCRIPTION_SHA256" && $FORCE == 0 ]]; then
    die 'subscription changed after extra install; inspect it or use --force intentionally'
  fi
  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  if command -v ufw >/dev/null 2>&1; then
    if [[ $UFW_ANYTLS_ADDED == 1 ]]; then
      ufw --force delete allow "$ANYTLS_PORT/tcp" comment "$UFW_COMMENT_ANYTLS" || true
    fi
    if [[ $UFW_TUIC_ADDED == 1 ]]; then
      ufw --force delete allow "$TUIC_PORT/udp" comment "$UFW_COMMENT_TUIC" || true
    fi
  fi
  install -o "$SUBSCRIPTION_UID" -g "$SUBSCRIPTION_GID" -m "$SUBSCRIPTION_MODE" \
    "$BACKUP_DIR/subscription.yaml" "$SUBSCRIPTION_FILE"
  [[ $(sha256_file "$SUBSCRIPTION_FILE") == "$BASELINE_SUBSCRIPTION_SHA256" ]] || die 'subscription rollback hash mismatch'
  rm -f "$UNIT_PATH" "$EXTRA_CONFIG" "$RENEW_HOOK"
  systemctl daemon-reload
  ! tcp_port_in_use "$ANYTLS_PORT" || die "TCP $ANYTLS_PORT remains occupied"
  ! udp_port_in_use "$TUIC_PORT" || die "UDP $TUIC_PORT remains occupied"
  rm -f "$STATE_FILE" "$CLI_PATH"
  rm -rf -- "$STATE_DIR"
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
    publish) publish_overlay ;;
    status) status_overlay ;;
    verify) verify_overlay ;;
    rollback) rollback_overlay ;;
    *) die "unknown command: $command" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
