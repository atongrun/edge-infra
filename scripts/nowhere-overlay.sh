#!/usr/bin/env bash
# Optional independent Nowhere v3 relay. It never edits base edge-infra files.
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
UNIT_NAME=edge-infra-nowhere.service
UNIT_PATH=/etc/systemd/system/$UNIT_NAME
SERVICE_USER=edge-nowhere
CONFIG_DIR=/etc/edge-infra-nowhere
RUNTIME_ENV=$CONFIG_DIR/runtime.env
CERT_DIR=$CONFIG_DIR/certs
STATE_DIR=/var/lib/edge-infra-nowhere
STATE_FILE=$STATE_DIR/state.env
BACKUP_ROOT=/var/backups/edge-infra-nowhere
BIN_DIR=/usr/local/lib/edge-infra-nowhere
BIN_PATH=$BIN_DIR/nowhere
CLI_PATH=/usr/local/sbin/edge-infra-nowhere
HOOK_PATH=/etc/letsencrypt/renewal-hooks/deploy/edge-infra-nowhere-reload
UFW_COMMENT=edge-infra-nowhere
VERSION=v3.0.1
CONFIG_FILE='' ASSUME_YES=0 FORCE=0
CREATED_UFW_TCP=0 CREATED_UFW_UDP=0
INSTALLING=0 CREATED_GROUP=0 CREATED_USER=0 CREATED_STATE_DIR=0 CREATED_CONFIG_DIR=0
CREATED_BIN_DIR=0 CREATED_UNIT=0 CREATED_HOOK=0
PREVIOUS_CERT_DIR=''

log() { printf '[edge-infra-nowhere] %s\n' "$*"; }
warn() { printf '[edge-infra-nowhere] WARNING: %s\n' "$*" >&2; }
die() { printf '[edge-infra-nowhere] ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { (( EUID == 0 )) || die 'run as root'; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
sha256_file() { sha256sum "$1" | awk '{print $1}'; }
source_cert_dir() { printf '/etc/letsencrypt/live/%s' "$NOWHERE_CERT_NAME"; }
ufw_is_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
tcp_port_in_use() { ss -H -lnt | awk -v p="$1" '{a=$4;sub(/^.*:/,"",a);if(a==p)x=1} END{exit !x}'; }
udp_port_in_use() { ss -H -lnu | awk -v p="$1" '{a=$4;sub(/^.*:/,"",a);if(a==p)x=1} END{exit !x}'; }

usage() {
  cat <<'EOF'
Usage:
  nowhere-overlay.sh preflight --config FILE
  nowhere-overlay.sh install   --config FILE --yes
  nowhere-overlay.sh status
  nowhere-overlay.sh verify
  nowhere-overlay.sh renew
  nowhere-overlay.sh rollback  --yes [--force]
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
  NOWHERE_PUBLIC_HOST='' NOWHERE_CERT_NAME='' NOWHERE_TCP_PORT=10443 NOWHERE_UDP_PORT=10443
  NOWHERE_TRANSPORT_MEMORY_PROFILE=memory FIREWALL_MODE=auto
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}; [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die "invalid config line: $line"
    key=${line%%=*}; value=${line#*=}
    [[ $key =~ ^[A-Z0-9_]+$ ]] || die "invalid config key: $key"
    [[ $seen != *" $key "* ]] || die "duplicate config key: $key"; seen+="$key "
    case "$key" in
      NOWHERE_PUBLIC_HOST) NOWHERE_PUBLIC_HOST=$value ;;
      NOWHERE_CERT_NAME) NOWHERE_CERT_NAME=$value ;;
      NOWHERE_TCP_PORT) NOWHERE_TCP_PORT=$value ;;
      NOWHERE_UDP_PORT) NOWHERE_UDP_PORT=$value ;;
      NOWHERE_TRANSPORT_MEMORY_PROFILE) NOWHERE_TRANSPORT_MEMORY_PROFILE=$value ;;
      FIREWALL_MODE) FIREWALL_MODE=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"
  valid_domain "$NOWHERE_PUBLIC_HOST" || die 'NOWHERE_PUBLIC_HOST must be a valid FQDN'
  valid_domain "$NOWHERE_CERT_NAME" || die 'NOWHERE_CERT_NAME must be a valid FQDN'
  valid_port "$NOWHERE_TCP_PORT" || die 'NOWHERE_TCP_PORT must be 1024..65535'
  valid_port "$NOWHERE_UDP_PORT" || die 'NOWHERE_UDP_PORT must be 1024..65535'
  [[ $NOWHERE_TRANSPORT_MEMORY_PROFILE =~ ^(memory|balanced|throughput)$ ]] || die 'invalid transport memory profile'
  [[ $FIREWALL_MODE == auto || $FIREWALL_MODE == none ]] || die 'FIREWALL_MODE must be auto or none'
}

detect_asset() {
  local arch libc=gnu
  case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) die "unsupported architecture: $(uname -m)" ;; esac
  command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl && libc=musl
  NOWHERE_ASSET="nowhere-${arch}-unknown-linux-${libc}.tar.gz"
  case "$NOWHERE_ASSET" in
    nowhere-x86_64-unknown-linux-gnu.tar.gz) NOWHERE_SHA256=261ceaa63f34915f6fa62545d59d75e9a8876112fe5b6c7f47897c7a818b82ea ;;
    nowhere-x86_64-unknown-linux-musl.tar.gz) NOWHERE_SHA256=2d5b4d1952013eb787fe9b900e04ba82f66acc995a563fa5bd66caa5053027c7 ;;
    nowhere-aarch64-unknown-linux-gnu.tar.gz) NOWHERE_SHA256=93704f0d0116e8332b50c21dc0d9b1c13e12f40b5bc6608e805be11cba5f9a87 ;;
    nowhere-aarch64-unknown-linux-musl.tar.gz) NOWHERE_SHA256=122002f9a0665862c771a9060dda9d2fdd750dac751cc06376db8966214b7190 ;;
    *) die "no pinned digest for $NOWHERE_ASSET" ;;
  esac
}

cert_pair_valid() {
  local cert=$1 key=$2 cert_pub key_pub
  [[ -f $cert && ! -L $cert && -r $cert ]] || return 1
  [[ -f $key && ! -L $key && -r $key ]] || return 1
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  key_pub=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}') || return 1
  [[ -n $cert_pub && $cert_pub == "$key_pub" ]]
}

cert_is_usable_for_host() {
  local cert=$1
  openssl x509 -in "$cert" -noout -checkhost "$NOWHERE_PUBLIC_HOST" >/dev/null 2>&1 && openssl x509 -in "$cert" -noout -checkend 60 >/dev/null 2>&1
}

source_cert_pair() {
  local source_dir=$1 full key archive_prefix
  source_dir=$(readlink -f -- "$source_dir") || return 1
  full=$(readlink -f -- "$source_dir/fullchain.pem") || return 1
  key=$(readlink -f -- "$source_dir/privkey.pem") || return 1
  archive_prefix="/etc/letsencrypt/archive/${NOWHERE_CERT_NAME}/"
  [[ $full == "$archive_prefix"* && $key == "$archive_prefix"* ]] || return 1
  cert_pair_valid "$full" "$key" || return 1
  cert_is_usable_for_host "$full" || return 1
  SOURCE_FULLCHAIN=$full SOURCE_PRIVKEY=$key
}

check_clean_target() {
  [[ ! -e $STATE_FILE && ! -e $CONFIG_DIR && ! -e $BIN_DIR && ! -e $UNIT_PATH && ! -e $HOOK_PATH && ! -e $CLI_PATH ]] || die 'Nowhere overlay paths already exist; use status or rollback'
  [[ $(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true) == not-found ]] || die "$UNIT_NAME is already registered"
  if getent passwd "$SERVICE_USER" >/dev/null; then
    [[ $(getent passwd "$SERVICE_USER" | cut -d: -f6,7) == /nonexistent:/usr/sbin/nologin ]] || die "existing $SERVICE_USER account has unexpected home or shell"
  fi
  if getent group "$SERVICE_USER" >/dev/null; then :; fi
}

preflight() {
  require_root; [[ -n $CONFIG_FILE ]] || die '--config is required'; load_config
  [[ $(uname -s) == Linux ]] || die 'Nowhere overlay supports Linux only'
  for command in curl tar sha256sum openssl ss systemctl install getent useradd groupadd readlink runuser; do require_command "$command"; done
  detect_asset; check_clean_target
  ! tcp_port_in_use "$NOWHERE_TCP_PORT" || die "TCP $NOWHERE_TCP_PORT is already in use"
  ! udp_port_in_use "$NOWHERE_UDP_PORT" || die "UDP $NOWHERE_UDP_PORT is already in use"
  local source_dir; source_dir=$(source_cert_dir)
  source_cert_pair "$source_dir" || die "certificate/key are unreadable, outside the expected Let’s Encrypt archive, or do not match in $source_dir"
  if [[ $FIREWALL_MODE == auto ]] && ufw_is_active; then ! ufw status numbered 2>/dev/null | grep -Fq "$UFW_COMMENT" || die 'owned UFW rule already exists'; fi
  log "preflight passed: $NOWHERE_ASSET, TCP $NOWHERE_TCP_PORT, UDP $NOWHERE_UDP_PORT, $NOWHERE_TRANSPORT_MEMORY_PROFILE profile"
  warn 'Upstream Nowhere requires its shared key in the process argv. A dedicated non-login user narrows exposure, but hosts without restrictive /proc policy can expose argv to other local users.'
}

stage_certificates() {
  local source_dir stage old
  source_dir=$(source_cert_dir)
  source_cert_pair "$source_dir" || die 'source certificate/key changed, escaped its expected archive, or does not match'
  stage=$(mktemp -d "$CONFIG_DIR/.cert-stage.XXXXXX")
  install -m 0640 -o root -g "$SERVICE_USER" "$SOURCE_FULLCHAIN" "$stage/fullchain.pem"
  install -m 0640 -o root -g "$SERVICE_USER" "$SOURCE_PRIVKEY" "$stage/privkey.pem"
  cert_pair_valid "$stage/fullchain.pem" "$stage/privkey.pem" || die 'staged certificate/key validation failed'
  cert_is_usable_for_host "$stage/fullchain.pem" || die 'staged certificate does not match public host or is expiring'
  old="$CONFIG_DIR/.cert-old.$(date +%s)"
  PREVIOUS_CERT_DIR=''
  if [[ -e $CERT_DIR ]]; then mv "$CERT_DIR" "$old"; PREVIOUS_CERT_DIR=$old; fi
  if ! mv "$stage" "$CERT_DIR"; then [[ ! -e $old ]] || mv "$old" "$CERT_DIR"; die 'failed to activate staged certificate pair'; fi
  if ! chown root:"$SERVICE_USER" "$CERT_DIR" || ! chmod 0750 "$CERT_DIR"; then
    rm -rf "$CERT_DIR"; [[ ! -e $old ]] || mv "$old" "$CERT_DIR"
    die 'failed to set staged certificate directory permissions'
  fi
}

discard_previous_cert() { [[ -z $PREVIOUS_CERT_DIR ]] || rm -rf "$PREVIOUS_CERT_DIR"; PREVIOUS_CERT_DIR=''; }
restore_previous_cert() {
  [[ -n $PREVIOUS_CERT_DIR && -d $PREVIOUS_CERT_DIR ]] || return 0
  rm -rf "$CERT_DIR"; mv "$PREVIOUS_CERT_DIR" "$CERT_DIR"; PREVIOUS_CERT_DIR=''
}

archive_overlay_for_rollback() {
  local archive
  archive=$BACKUP_DIR/removed-overlay
  [[ ! -e $archive ]] || die 'rollback archive already exists; refusing to overwrite recovery material'
  install -d -m 0700 "$archive"
  cp -a -- "$CONFIG_DIR" "$archive/etc-edge-infra-nowhere"
  cp -p -- "$STATE_FILE" "$archive/state.env"
  cp -p -- "$UNIT_PATH" "$archive/edge-infra-nowhere.service"
  cp -p -- "$CLI_PATH" "$archive/edge-infra-nowhere"
  cp -p -- "$BIN_PATH" "$archive/nowhere"
  cp -p -- "$HOOK_PATH" "$archive/edge-infra-nowhere-reload"
  cp -p -- "$BACKUP_DIR/owned-files.sha256" "$archive/owned-files.sha256"
  (
    cd "$archive"
    sha256sum state.env edge-infra-nowhere.service edge-infra-nowhere nowhere edge-infra-nowhere-reload owned-files.sha256 \
      etc-edge-infra-nowhere/runtime.env etc-edge-infra-nowhere/certs/fullchain.pem etc-edge-infra-nowhere/certs/privkey.pem > archive-files.sha256
    sha256sum -c archive-files.sha256 >/dev/null
  ) || die 'rollback archive checksum validation failed'
  chmod 0600 "$archive/archive-files.sha256" "$archive/owned-files.sha256"
}

write_runtime_env() {
  local key=$1 endpoint
  endpoint="*/tcp:${NOWHERE_TCP_PORT}/udp:${NOWHERE_UDP_PORT}"
  install -m 0600 /dev/null "$RUNTIME_ENV"
  cat > "$RUNTIME_ENV" <<EOF
NOWHERE_SERVICE_URL="portal://${key}@${endpoint}?out=direct&tls=2&crt=${CERT_DIR}/fullchain.pem&key=${CERT_DIR}/privkey.pem&morph=1"
NOW_TRANSPORT_MEMORY_PROFILE=${NOWHERE_TRANSPORT_MEMORY_PROFILE}
EOF
  chown root:root "$RUNTIME_ENV"
}

write_hook() {
  cat > "$HOOK_PATH" <<EOF
#!/bin/sh
set -eu
[ "\${RENEWED_LINEAGE:-}" = "$(source_cert_dir)" ] || exit 0
/usr/local/sbin/edge-infra-nowhere renew
EOF
  chmod 0750 "$HOOK_PATH"; chown root:root "$HOOK_PATH"
}

download_binary() {
  local tmp archive actual
  tmp=$(mktemp -d); archive=$tmp/$NOWHERE_ASSET
  curl -fL --retry 3 --connect-timeout 10 -o "$archive" "https://github.com/NodePassProject/Nowhere/releases/download/$VERSION/$NOWHERE_ASSET"
  actual=$(sha256_file "$archive"); [[ $actual == "$NOWHERE_SHA256" ]] || { rm -rf "$tmp"; die "official digest mismatch for $NOWHERE_ASSET"; }
  tar -xzf "$archive" -C "$tmp"; [[ -f $tmp/nowhere && ! -L $tmp/nowhere ]] || { rm -rf "$tmp"; die 'release archive has no regular nowhere binary'; }
  install -m 0755 -o root -g root "$tmp/nowhere" "$BIN_PATH"; rm -rf "$tmp"
  "$BIN_PATH" --version | grep -Fq "$VERSION" || die 'downloaded Nowhere version does not match pin'
}

write_state() {
  cat > "$STATE_FILE.tmp" <<EOF
BACKUP_DIR=$BACKUP_DIR
NOWHERE_PUBLIC_HOST=$NOWHERE_PUBLIC_HOST
NOWHERE_CERT_NAME=$NOWHERE_CERT_NAME
NOWHERE_TCP_PORT=$NOWHERE_TCP_PORT
NOWHERE_UDP_PORT=$NOWHERE_UDP_PORT
NOWHERE_ASSET=$NOWHERE_ASSET
NOWHERE_SHA256=$NOWHERE_SHA256
UFW_TCP=$CREATED_UFW_TCP
UFW_UDP=$CREATED_UFW_UDP
EOF
  chmod 0600 "$STATE_FILE.tmp"; mv "$STATE_FILE.tmp" "$STATE_FILE"
}

manifest_line() {
  local path=$1 digest
  digest=$(sha256_file "$path") || return 1
  [[ $digest =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s  %s\n' "$digest" "$path"
}
write_manifest() {
  local manifest=$BACKUP_DIR/owned-files.sha256 tmp=$BACKUP_DIR/.owned-files.sha256.tmp
  if ! {
    manifest_line "$BIN_PATH"
    manifest_line "$UNIT_PATH"
    manifest_line "$CLI_PATH"
    manifest_line "$RUNTIME_ENV"
    manifest_line "$CERT_DIR/fullchain.pem"
    manifest_line "$CERT_DIR/privkey.pem"
    manifest_line "$HOOK_PATH"
  } > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$manifest" || { rm -f "$tmp"; return 1; }
}

verify_manifest() {
  local manifest=$BACKUP_DIR/owned-files.sha256 path
  [[ -f $manifest && ! -L $manifest ]] || return 1
  [[ $(wc -l < "$manifest") -eq 7 ]] || return 1
  for path in "$BIN_PATH" "$UNIT_PATH" "$CLI_PATH" "$RUNTIME_ENV" "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$HOOK_PATH"; do
    awk -v p="$path" '$2 == p {n++} END {exit n == 1 ? 0 : 1}' "$manifest" || return 1
  done
  sha256sum -c "$manifest" >/dev/null 2>&1
}

install_all() {
  require_root; [[ $ASSUME_YES == 1 ]] || die 'install requires --yes'; preflight
  INSTALLING=1
  BACKUP_DIR=$BACKUP_ROOT/$(date +%Y%m%d%H%M%S)
  install -d -m 0700 "$BACKUP_DIR" "$STATE_DIR"; CREATED_STATE_DIR=1
  printf '%s  %s\n' "$NOWHERE_SHA256" "$NOWHERE_ASSET" > "$BACKUP_DIR/official-digest.txt"
  for unit in edge-infra-hy2.service edge-infra-trojan.service sing-box-reality.service nginx.service; do printf '%s=%s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"; done > "$BACKUP_DIR/base-unit-snapshot.env"
  if ! getent group "$SERVICE_USER" >/dev/null; then groupadd --system "$SERVICE_USER"; CREATED_GROUP=1; fi
  if ! getent passwd "$SERVICE_USER" >/dev/null; then useradd --system --gid "$SERVICE_USER" --home-dir /nonexistent --shell /usr/sbin/nologin "$SERVICE_USER"; CREATED_USER=1; fi
  install -d -m 0750 -o root -g "$SERVICE_USER" "$CONFIG_DIR"; CREATED_CONFIG_DIR=1
  install -d -m 0755 "$BIN_DIR"; CREATED_BIN_DIR=1
  stage_certificates
  key=$(openssl rand -hex 16); write_runtime_env "$key"; key=''
  download_binary
  install -m 0644 "$PROJECT_ROOT/templates/systemd/edge-infra-nowhere.service" "$UNIT_PATH"; CREATED_UNIT=1
  install -m 0755 "$PROJECT_ROOT/scripts/nowhere-overlay.sh" "$CLI_PATH"
  write_hook; CREATED_HOOK=1
  systemctl daemon-reload
  command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze verify "$UNIT_PATH"
  if [[ $FIREWALL_MODE == auto ]] && ufw_is_active; then
    ufw allow "$NOWHERE_TCP_PORT/tcp" comment "$UFW_COMMENT"; CREATED_UFW_TCP=1
    ufw allow "$NOWHERE_UDP_PORT/udp" comment "$UFW_COMMENT"; CREATED_UFW_UDP=1
  fi
  systemctl enable --now "$UNIT_NAME"; write_state; write_manifest; verify; discard_previous_cert
  INSTALLING=0
  log 'installed independent Nowhere backup relay'
}

cleanup_failed_install() {
  local status=${1:-$?}
  (( INSTALLING == 1 )) || return 0
  set +e
  warn 'install failed; removing only resources created by this attempt'
  (( CREATED_UNIT == 0 )) || { systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true; rm -f "$UNIT_PATH"; systemctl daemon-reload || true; }
  (( CREATED_HOOK == 0 )) || rm -f "$HOOK_PATH"
  rm -f "$CLI_PATH"
  (( CREATED_UFW_TCP == 0 )) || ufw --force delete allow "$NOWHERE_TCP_PORT/tcp" comment "$UFW_COMMENT" >/dev/null 2>&1 || true
  (( CREATED_UFW_UDP == 0 )) || ufw --force delete allow "$NOWHERE_UDP_PORT/udp" comment "$UFW_COMMENT" >/dev/null 2>&1 || true
  (( CREATED_BIN_DIR == 0 )) || rm -rf "$BIN_DIR"
  (( CREATED_CONFIG_DIR == 0 )) || rm -rf "$CONFIG_DIR"
  rm -f "$STATE_FILE"
  (( CREATED_STATE_DIR == 0 )) || rmdir "$STATE_DIR" 2>/dev/null || true
  (( CREATED_USER == 0 )) || userdel "$SERVICE_USER" >/dev/null 2>&1 || true
  (( CREATED_GROUP == 0 )) || groupdel "$SERVICE_USER" >/dev/null 2>&1 || true
  return "$status"
}
trap 'status=$?; cleanup_failed_install "$status"; exit "$status"' EXIT

load_state() { [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die 'Nowhere overlay is not installed'; set -a; . "$STATE_FILE"; set +a; }
wait_for_listener() {
  local protocol=$1 port=$2
  for _ in {1..20}; do
    [[ $protocol == tcp ]] && ss -H -lntp | grep -Eq ":${port}[[:space:]].*nowhere" && return 0
    [[ $protocol == udp ]] && ss -H -lnup | grep -Eq ":${port}[[:space:]].*nowhere" && return 0
    sleep 0.25
  done
  return 1
}
verify() {
  require_root; load_state
  [[ -x $BIN_PATH ]] || die 'Nowhere binary missing'
  verify_manifest || die 'owned-files manifest is missing or does not match; refusing to trust overlay state'
  systemctl is-enabled --quiet "$UNIT_NAME" || die 'Nowhere unit is not enabled'
  systemctl is-active --quiet "$UNIT_NAME" || die 'Nowhere unit is not active'
  wait_for_listener tcp "$NOWHERE_TCP_PORT" || die "Nowhere is not listening on TCP $NOWHERE_TCP_PORT"
  wait_for_listener udp "$NOWHERE_UDP_PORT" || die "Nowhere is not listening on UDP $NOWHERE_UDP_PORT"
  [[ $(stat -c '%U:%G:%a' "$CONFIG_DIR") == root:edge-nowhere:750 ]] || die 'config directory permissions changed'
  [[ $(stat -c '%U:%G:%a' "$RUNTIME_ENV") == root:root:600 ]] || die 'runtime environment permissions changed'
  cert_pair_valid "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" || die 'copied certificate/key validation failed'
  cert_is_usable_for_host "$CERT_DIR/fullchain.pem" || die 'copied certificate does not match public host or is expiring'
  runuser -u "$SERVICE_USER" -- test -r "$CERT_DIR/fullchain.pem" -a -r "$CERT_DIR/privkey.pem" || die 'service user cannot read copied certificate pair'
  command -v systemd-analyze >/dev/null 2>&1 && systemd-analyze verify "$UNIT_PATH"
  log 'verify passed: local process, TCP/UDP listeners, permissions, and certificate copy'
  log 'this does not prove a remote Vector, HTTPS payload, or client routing path'
}
status() {
  require_root; load_state
  printf 'service=%s\nenabled=%s\nendpoint=%s tcp=%s udp=%s\nasset=%s digest=%s\n' "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)" "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)" "$NOWHERE_PUBLIC_HOST" "$NOWHERE_TCP_PORT" "$NOWHERE_UDP_PORT" "$NOWHERE_ASSET" "$NOWHERE_SHA256"
  runuser -u "$SERVICE_USER" -- env TMPDIR=/run/edge-infra-nowhere XDG_RUNTIME_DIR=/run/edge-infra-nowhere "$BIN_PATH" status || warn 'telemetry snapshot is unavailable'
}
renew() {
  local saved_manifest
  require_root; load_state
  verify_manifest || die 'owned-files manifest is missing or does not match; refusing certificate renewal'
  saved_manifest=$(mktemp "$BACKUP_DIR/.owned-files.before-renew.XXXXXX")
  cp -p "$BACKUP_DIR/owned-files.sha256" "$saved_manifest"
  stage_certificates
  if ! systemctl restart "$UNIT_NAME" || ! systemctl is-active --quiet "$UNIT_NAME" || ! wait_for_listener tcp "$NOWHERE_TCP_PORT" || ! wait_for_listener udp "$NOWHERE_UDP_PORT"; then
    warn 'new certificate did not produce a healthy Nowhere service; restoring prior certificate copy'
    restore_previous_cert
    cp -p "$saved_manifest" "$BACKUP_DIR/owned-files.sha256"
    systemctl restart "$UNIT_NAME" || die 'failed to restore Nowhere service with prior certificate'
    ( verify ) || die 'restored Nowhere service did not pass verification'
    rm -f "$saved_manifest"
    die 'certificate renewal failed; prior certificate copy was restored'
  fi
  if ! write_manifest; then
    warn 'could not update the owned-files manifest; restoring prior certificate copy'
    restore_previous_cert
    cp -p "$saved_manifest" "$BACKUP_DIR/owned-files.sha256"
    systemctl restart "$UNIT_NAME" || die 'failed to restore Nowhere service with prior certificate'
    ( verify ) || die 'restored Nowhere service did not pass verification'
    rm -f "$saved_manifest"
    die 'certificate renewal failed; prior certificate copy was restored'
  fi
  if ! ( verify ); then
    warn 'new certificate did not pass verification; restoring prior certificate copy'
    restore_previous_cert
    cp -p "$saved_manifest" "$BACKUP_DIR/owned-files.sha256"
    systemctl restart "$UNIT_NAME" || die 'failed to restore Nowhere service with prior certificate'
    ( verify ) || die 'restored Nowhere service did not pass verification'
    rm -f "$saved_manifest"
    die 'certificate renewal failed; prior certificate copy was restored'
  fi
  rm -f "$saved_manifest"; discard_previous_cert
  log 'renewed certificate copy and restarted only edge-infra-nowhere'
}
rollback() {
  require_root; [[ $ASSUME_YES == 1 ]] || die 'rollback requires --yes'; load_state
  [[ -n ${BACKUP_DIR:-} && -d $BACKUP_DIR ]] || die 'backup manifest missing; refusing rollback'
  if ! verify_manifest; then [[ $FORCE == 1 ]] || die 'owned-files manifest is missing or does not match; refusing rollback'; warn 'forcing rollback despite owned-files manifest mismatch'; fi
  if [[ ${UFW_TCP:-0} == 1 ]] && command -v ufw >/dev/null 2>&1 && ufw_is_active && ! ufw status | grep -F "$NOWHERE_TCP_PORT/tcp" | grep -Fq "$UFW_COMMENT"; then [[ $FORCE == 1 ]] || die 'owned TCP UFW rule is missing; refusing rollback'; warn 'forcing rollback despite missing TCP UFW rule'; fi
  if [[ ${UFW_UDP:-0} == 1 ]] && command -v ufw >/dev/null 2>&1 && ufw_is_active && ! ufw status | grep -F "$NOWHERE_UDP_PORT/udp" | grep -Fq "$UFW_COMMENT"; then [[ $FORCE == 1 ]] || die 'owned UDP UFW rule is missing; refusing rollback'; warn 'forcing rollback despite missing UDP UFW rule'; fi
  archive_overlay_for_rollback
  if [[ ${UFW_TCP:-0} == 1 ]] && command -v ufw >/dev/null 2>&1; then ufw --force delete allow "$NOWHERE_TCP_PORT/tcp" comment "$UFW_COMMENT" >/dev/null 2>&1 || [[ $FORCE == 1 ]] || die 'failed to remove owned TCP UFW rule'; fi
  if [[ ${UFW_UDP:-0} == 1 ]] && command -v ufw >/dev/null 2>&1; then ufw --force delete allow "$NOWHERE_UDP_PORT/udp" comment "$UFW_COMMENT" >/dev/null 2>&1 || [[ $FORCE == 1 ]] || die 'failed to remove owned UDP UFW rule'; fi
  systemctl disable --now "$UNIT_NAME" || die 'failed to stop and disable Nowhere unit'
  ! systemctl is-active --quiet "$UNIT_NAME" || die 'Nowhere unit remains active after stop'
  ! tcp_port_in_use "$NOWHERE_TCP_PORT" || die "TCP $NOWHERE_TCP_PORT remains occupied"
  ! udp_port_in_use "$NOWHERE_UDP_PORT" || die "UDP $NOWHERE_UDP_PORT remains occupied"
  rm -f "$UNIT_PATH" "$HOOK_PATH" "$BIN_PATH" "$CLI_PATH"; rm -rf "$CONFIG_DIR"
  systemctl daemon-reload
  rm -f "$STATE_FILE"
  rmdir "$BIN_DIR" 2>/dev/null || true; rmdir "$STATE_DIR" 2>/dev/null || true
  log "rolled back overlay resources; root-only recovery archive retained at $BACKUP_DIR/removed-overlay and service user retained"
}

main() {
  local action=${1:-}; [[ -n $action ]] || { usage; exit 2; }; shift
  parse_options "$@"
  case "$action" in
    preflight) preflight ;; install) install_all ;; status) status ;; verify) verify ;; renew) renew ;; rollback) rollback ;;
    *) die "unknown action: $action" ;;
  esac
}
if [[ ${EDGE_INFRA_NOWHERE_SOURCE_ONLY:-0} != 1 ]]; then main "$@"; fi
