#!/usr/bin/env bash
# Independent Cloudflare XHTTP overlay: nginx -> loopback Xray (VLESS/XHTTP).
set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

ETC=${CF_ETC_OVERRIDE:-/etc/edge-infra-cloudflare}
LIB=${CF_LIB_OVERRIDE:-/usr/local/lib/edge-infra-cloudflare}
STATE_DIR=${CF_STATE_DIR_OVERRIDE:-/var/lib/edge-infra-cloudflare}
STATE_FILE=$STATE_DIR/state.env
BACKUP_ROOT=${CF_BACKUP_ROOT_OVERRIDE:-/var/backups/edge-infra-cloudflare}
UNIT_DIR=${CF_UNIT_DIR_OVERRIDE:-/etc/systemd/system}
UNIT_NAME=edge-infra-xray-cf.service
UNIT_PATH=$UNIT_DIR/$UNIT_NAME
NGINX_SITE=${CF_NGINX_SITE_OVERRIDE:-/etc/nginx/sites-available/edge-infra-cloudflare.conf}
NGINX_LINK=${CF_NGINX_LINK_OVERRIDE:-/etc/nginx/sites-enabled/edge-infra-cloudflare.conf}
NGINX_CONF_ROOT=${CF_NGINX_ROOT_OVERRIDE:-/etc/nginx}
XRAY_CONFIG=$ETC/xray.json
XRAY_BIN=$LIB/xray
BASE_STATE=${EDGE_INFRA_BASE_STATE:-/var/lib/edge-infra/state.env}
REALITY_STATE=${EDGE_INFRA_REALITY_STATE:-/var/lib/edge-infra-reality/state.env}
VERSIONS_FILE=${RESILIENCE_VERSIONS_FILE:-$ROOT/env/resilience-versions.env.example}
XRAY_TEMPLATE=$ROOT/templates/xray/cloudflare-xhttp.json
NGINX_TEMPLATE=$ROOT/templates/nginx/cloudflare-xhttp.conf
UNIT_TEMPLATE=$ROOT/templates/systemd/edge-infra-xray-cf.service

CONF=''
ASSUME_YES=0
SUBSCRIPTION_FILE=''
INSTALLING=0
TMP=''
ARCH=''

log() { printf '[edge-infra-cloudflare] %s\n' "$*"; }
warn() { printf '[edge-infra-cloudflare] WARNING: %s\n' "$*" >&2; }
die() { printf '[edge-infra-cloudflare] ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
require_root() { ((EUID == 0)) || die 'run as root'; }
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
valid_ipv4() {
  local part
  local -a parts
  IFS=. read -r -a parts <<<"$1"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$part <= 255)) || return 1
  done
}
valid_ip() {
  [[ -z $1 ]] && return 0
  valid_ipv4 "$1" && return 0
  [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:]+$ ]]
}
sha256_file() { sha256sum "$1" | awk '{print $1}'; }

usage() {
  cat <<'EOF'
Usage:
  cloudflare-overlay.sh preflight --config FILE
  cloudflare-overlay.sh install   --config FILE --yes
  cloudflare-overlay.sh status
  cloudflare-overlay.sh verify
  cloudflare-overlay.sh rollback --yes [--subscription FILE]

The overlay owns only /etc/edge-infra-cloudflare,
/usr/local/lib/edge-infra-cloudflare, /var/lib/edge-infra-cloudflare,
edge-infra-xray-cf.service and its own nginx site file. It does not edit DNS,
Cloudflare settings, the base nginx site, or existing direct hostnames.
EOF
}

parse_options() {
  while (($#)); do
    case "$1" in
      --config) (($# >= 2)) || die '--config requires a path'; CONF=$2; shift 2 ;;
      --subscription) (($# >= 2)) || die '--subscription requires a path'; SUBSCRIPTION_FILE=$2; shift 2 ;;
      --yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

load_config() {
  local line key value seen=' '
  [[ -f $CONF && ! -L $CONF ]] || die 'config must be a regular non-symlink file'
  CF_HOSTNAME=''; CF_CERT_NAME=''; CF_XRAY_PORT=''; CF_XHTTP_PATH=''; CF_PREFERRED_IP=''
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die 'malformed config line'
    key=${line%%=*}; value=${line#*=}
    [[ $key =~ ^[A-Z0-9_]+$ ]] || die "invalid config key: $key"
    [[ $seen != *" $key "* ]] || die "duplicate config key: $key"
    seen+="$key "
    case "$key" in
      CF_HOSTNAME) CF_HOSTNAME=$value ;;
      CF_CERT_NAME) CF_CERT_NAME=$value ;;
      CF_XRAY_PORT) CF_XRAY_PORT=$value ;;
      CF_XHTTP_PATH) CF_XHTTP_PATH=$value ;;
      CF_PREFERRED_IP) CF_PREFERRED_IP=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$CONF"
  valid_domain "$CF_HOSTNAME" || die 'CF_HOSTNAME must be a valid FQDN'
  CF_HOSTNAME=${CF_HOSTNAME,,}
  [[ -n $CF_CERT_NAME ]] || CF_CERT_NAME=$CF_HOSTNAME
  [[ $CF_CERT_NAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'CF_CERT_NAME is invalid'
  valid_port "$CF_XRAY_PORT" || die 'CF_XRAY_PORT must be a valid port'
  [[ $CF_XHTTP_PATH =~ ^/[A-Za-z0-9/_-]{1,128}$ ]] || die 'CF_XHTTP_PATH is invalid'
  [[ $CF_XHTTP_PATH != *//* ]] || die 'CF_XHTTP_PATH must not contain //'
  valid_ip "$CF_PREFERRED_IP" || die 'CF_PREFERRED_IP must be empty, IPv4 or IPv6'
}

load_state() {
  [[ -f $STATE_FILE && ! -L $STATE_FILE ]] || die "Cloudflare overlay is not installed: $STATE_FILE"
  # shellcheck disable=SC1090
  source "$STATE_FILE"
}

config_matches_state() {
  local want_host=$CF_HOSTNAME want_cert=$CF_CERT_NAME want_port=$CF_XRAY_PORT want_path=$CF_XHTTP_PATH want_ip=$CF_PREFERRED_IP
  load_state
  [[ $CF_HOSTNAME == "$want_host" && $CF_CERT_NAME == "$want_cert" && \
     $CF_XRAY_PORT == "$want_port" && $CF_XHTTP_PATH == "$want_path" && \
     $CF_PREFERRED_IP == "$want_ip" ]] \
    || die 'config differs from the installed overlay; roll it back before changing origin settings'
}

direct_hostnames() {
  local file key value
  for file in "$BASE_STATE" "$REALITY_STATE"; do
    [[ -f $file && ! -L $file ]] || continue
    while IFS='=' read -r key value; do
      case "$key" in
        EDGE_DOMAIN|SUB_DOMAIN|REALITY_SERVER)
          value=${value%$'\r'}
          value=${value#\"}; value=${value%\"}
          value=${value#\'}; value=${value%\'}
          [[ -n $value ]] && printf '%s\n' "$value"
          ;;
      esac
    done < "$file"
  done
}

check_direct_hostname_guard() {
  local name site_base link_base escaped
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    [[ $CF_HOSTNAME != "$name" ]] || die 'CF_HOSTNAME must be a NEW hostname, not an existing direct hostname'
  done < <(direct_hostnames)

  [[ -d $NGINX_CONF_ROOT ]] || return 0
  site_base=$(basename -- "$NGINX_SITE")
  link_base=$(basename -- "$NGINX_LINK")
  escaped=${CF_HOSTNAME//./\\.}
  if grep -RIsE --exclude="$site_base" --exclude="$link_base" \
      "server_name[^;#]*[[:space:]]${escaped}([[:space:];]|$)" \
      "$NGINX_CONF_ROOT" 2>/dev/null | grep -q .; then
    die 'CF_HOSTNAME already appears in an existing nginx server_name; refusing to touch direct hostnames'
  fi
}

port_in_use() {
  ss -H -lnt | awk -v target="$1" '{p=$4; sub(/^.*:/,"",p); if (p == target) found=1} END {exit found ? 0 : 1}'
}

loopback_listener_present() {
  ss -H -lnt | awk -v port="$CF_XRAY_PORT" '
    {if ($4 == "127.0.0.1:" port || $4 == "[::1]:" port) found=1}
    END {exit found ? 0 : 1}
  '
}

wait_for_listener() {
  local _
  for _ in {1..40}; do
    loopback_listener_present && return 0
    sleep 0.25
  done
  return 1
}

detect_arch() {
  case $(uname -m) in
    x86_64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) die 'unsupported architecture' ;;
  esac
}

load_versions() {
  [[ -f $VERSIONS_FILE && ! -L $VERSIONS_FILE ]] || die 'resilience version manifest is missing'
  # shellcheck disable=SC1090
  source "$VERSIONS_FILE"
  [[ ${XRAY_VERSION:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'XRAY_VERSION is invalid'
  if [[ $ARCH == amd64 ]]; then XRAY_SHA=${XRAY_AMD64_SHA256:-}; else XRAY_SHA=${XRAY_ARM64_SHA256:-}; fi
  [[ $XRAY_SHA =~ ^[a-f0-9]{64}$ ]] || die 'Xray checksum pin is missing or invalid'
}

certificate_checks() {
  local cert=/etc/letsencrypt/live/$CF_CERT_NAME/fullchain.pem key=/etc/letsencrypt/live/$CF_CERT_NAME/privkey.pem
  [[ -f $cert && -f $key && ! -L $cert && ! -L $key ]] || die 'certificate lineage is missing or is a symlink'
  openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || die 'origin certificate is expired'
  openssl x509 -in "$cert" -noout -checkhost "$CF_HOSTNAME" 2>/dev/null | grep -q 'does match' \
    || die 'origin certificate does not cover CF_HOSTNAME'
}

preflight() {
  require_root
  [[ -n $CONF ]] || die '--config is required'
  load_config
  for command in curl sha256sum python3 jq openssl ss systemctl flock nginx; do require_command "$command"; done
  detect_arch
  certificate_checks
  systemctl is-active --quiet nginx.service || die 'nginx.service is not active'
  nginx -t >/dev/null 2>&1 || die 'existing nginx configuration is invalid'
  check_direct_hostname_guard

  if [[ -f $STATE_FILE ]]; then
    config_matches_state
    [[ -f $XRAY_CONFIG && -f $UNIT_PATH && -x $XRAY_BIN ]] \
      || die 'existing overlay state is incomplete; roll it back before reinstalling'
    log 'preflight passed for the installed overlay'
    return 0
  fi

  [[ ! -e $ETC && ! -e $LIB && ! -e $STATE_DIR && ! -e $UNIT_PATH && \
     ! -e $NGINX_SITE && ! -e $NGINX_LINK && ! -L $NGINX_LINK ]] \
    || die 'an owned path already exists; inspect before install'
  [[ $(systemctl show -p LoadState --value "$UNIT_NAME" 2>/dev/null || true) == not-found ]] \
    || die "$UNIT_NAME is already registered"
  ! port_in_use "$CF_XRAY_PORT" || die "loopback port $CF_XRAY_PORT is already in use"
  log 'preflight passed'
}

render_xray_config() {
  local content
  [[ -f $XRAY_TEMPLATE ]] || die 'Xray template is missing'
  content=$(<"$XRAY_TEMPLATE")
  content=${content//\$\{CF_XRAY_PORT\}/$CF_XRAY_PORT}
  content=${content//\$\{CF_XHTTP_PATH\}/$CF_XHTTP_PATH}
  content=${content//\$\{CF_UUID\}/$CF_UUID}
  [[ ! $content =~ \$\{[A-Z0-9_]+\} ]] || die 'unresolved placeholder in Xray template'
  printf '%s\n' "$content"
}

render_nginx_site() {
  local content
  [[ -f $NGINX_TEMPLATE ]] || die 'nginx template is missing'
  content=$(<"$NGINX_TEMPLATE")
  content=${content//\$\{CF_HOSTNAME\}/$CF_HOSTNAME}
  content=${content//\$\{CF_CERT_NAME\}/$CF_CERT_NAME}
  content=${content//\$\{CF_XRAY_PORT\}/$CF_XRAY_PORT}
  content=${content//\$\{CF_XHTTP_PATH\}/$CF_XHTTP_PATH}
  [[ ! $content =~ \$\{[A-Z0-9_]+\} ]] || die 'unresolved placeholder in nginx template'
  printf '%s\n' "$content"
}

write_state() {
  {
    printf 'CF_HOSTNAME=%q\n' "$CF_HOSTNAME"
    printf 'CF_CERT_NAME=%q\n' "$CF_CERT_NAME"
    printf 'CF_XRAY_PORT=%q\n' "$CF_XRAY_PORT"
    printf 'CF_XHTTP_PATH=%q\n' "$CF_XHTTP_PATH"
    printf 'CF_PREFERRED_IP=%q\n' "$CF_PREFERRED_IP"
    printf 'CF_UUID=%q\n' "$CF_UUID"
    printf 'XRAY_VERSION=%q\n' "$XRAY_VERSION"
    printf 'XRAY_SHA256=%q\n' "$XRAY_SHA"
    printf 'INSTALL_ID=%q\n' "$INSTALL_ID"
  } > "$STATE_FILE.tmp"
  chmod 0600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

download_xray() {
  local asset destination=$1
  if [[ $ARCH == amd64 ]]; then asset=Xray-linux-64.zip; else asset=Xray-linux-arm64-v8a.zip; fi
  curl -fsSL --retry 2 \
    "https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/$asset" \
    -o "$destination"
  printf '%s  %s\n' "$XRAY_SHA" "$destination" | sha256sum -c --status \
    || die 'Xray checksum mismatch'
}

extract_xray() {
  python3 - "$1" "$2" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    member = next((name for name in archive.namelist()
                   if name.rsplit("/", 1)[-1] == "xray"), None)
    if member is None:
        raise SystemExit("xray binary not found in release archive")
    with archive.open(member) as source, open(sys.argv[2], "wb") as target:
        target.write(source.read())
PY
}

cleanup_install() {
  local status=$?
  trap - EXIT
  if ((INSTALLING)); then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH" "$NGINX_LINK" "$NGINX_SITE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
      systemctl reload nginx.service >/dev/null 2>&1 || true
    fi
    rm -rf -- "$ETC" "$LIB" "$STATE_DIR"
  fi
  [[ -z $TMP ]] || rm -rf -- "$TMP"
  exit "$status"
}

install_fresh() {
  local site_tmp
  load_versions
  TMP=$(mktemp -d /tmp/edge-cf-install.XXXXXX)
  trap cleanup_install EXIT
  trap 'exit 1' INT TERM

  download_xray "$TMP/xray.zip"
  extract_xray "$TMP/xray.zip" "$TMP/xray"
  chmod 0700 "$TMP/xray"
  CF_UUID=$("$TMP/xray" uuid)
  [[ $CF_UUID =~ ^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$ ]] \
    || die 'failed to generate a canonical UUID'
  render_xray_config > "$TMP/xray.json"
  "$TMP/xray" run -test -config "$TMP/xray.json" >/dev/null 2>&1 \
    || die 'Xray rejected the generated config'
  site_tmp=$TMP/nginx.conf
  render_nginx_site > "$site_tmp"

  INSTALLING=1
  INSTALL_ID=$(date -u +%Y%m%dT%H%M%SZ)
  install -d -m 0700 "$ETC" "$STATE_DIR"
  install -d -m 0755 "$LIB"
  install -m 0755 "$TMP/xray" "$XRAY_BIN"
  install -m 0600 "$TMP/xray.json" "$XRAY_CONFIG"
  printf '%s\n' "$CF_UUID" > "$STATE_DIR/uuid"
  chmod 0600 "$STATE_DIR/uuid"
  write_state
  install -m 0644 "$UNIT_TEMPLATE" "$UNIT_PATH"
  install -d -m 0755 "$(dirname -- "$NGINX_SITE")" "$(dirname -- "$NGINX_LINK")"
  install -m 0644 "$site_tmp" "$NGINX_SITE"
  ln -s "$NGINX_SITE" "$NGINX_LINK"

  nginx -t >/dev/null 2>&1 || die 'nginx rejected the generated site'
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
  systemctl reload nginx.service
  wait_for_listener || die 'Xray is not listening on the loopback port'
  verify_internal
  INSTALLING=0
  trap - EXIT INT TERM
  rm -rf -- "$TMP"
  TMP=''
  log "installed nginx -> 127.0.0.1:$CF_XRAY_PORT Xray XHTTP origin for $CF_HOSTNAME"
}

ensure_existing() {
  [[ -f $NGINX_SITE ]] || die 'owned nginx site file is missing; roll back and reinstall'
  if [[ ! -L $NGINX_LINK ]]; then
    [[ ! -e $NGINX_LINK ]] || die 'owned nginx link path is not a symlink'
    ln -s "$NGINX_SITE" "$NGINX_LINK"
  fi
  nginx -t >/dev/null 2>&1 || die 'nginx configuration is invalid'
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
  systemctl reload nginx.service
  wait_for_listener || die 'Xray is not listening on the loopback port'
  verify_internal
}

install_overlay() {
  ((ASSUME_YES == 1)) || die 'install requires --yes'
  preflight
  exec 9>/run/lock/edge-infra-cloudflare.lock
  flock -n 9 || die 'another Cloudflare overlay operation is running'
  if [[ -f $STATE_FILE ]]; then
    ensure_existing
    log 'overlay is already installed; no duplicate service or node was created'
    return 0
  fi
  install_fresh
}

status_overlay() {
  require_root
  load_state
  printf '%-24s %s\n' \
    SERVICE "$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)" \
    ENABLED "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || true)" \
    HOSTNAME "$CF_HOSTNAME" \
    CERT_NAME "$CF_CERT_NAME" \
    LOOPBACK_PORT "$CF_XRAY_PORT" \
    XHTTP_PATH 'set (not printed)' \
    PREFERRED_IP "${CF_PREFERRED_IP:-hostname}"
}

verify_internal() {
  load_state
  [[ -f $XRAY_CONFIG && ! -L $XRAY_CONFIG ]] || die 'Xray config is missing or invalid'
  [[ -x $XRAY_BIN ]] || die 'Xray binary is missing'
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || die 'installed Xray config is invalid'
  [[ -f $UNIT_PATH ]] || die 'Xray unit is missing'
  systemctl is-enabled --quiet "$UNIT_NAME" || die 'Xray service is not enabled'
  systemctl is-active --quiet "$UNIT_NAME" || die 'Xray service is not active'
  loopback_listener_present || die "Xray is not listening on 127.0.0.1:$CF_XRAY_PORT"
  systemctl is-active --quiet nginx.service || die 'nginx.service is not active'
  nginx -t >/dev/null 2>&1 || die 'nginx configuration is invalid'
  grep -Fq "server_name $CF_HOSTNAME" "$NGINX_SITE" || die 'nginx site does not serve CF_HOSTNAME'
  grep -Fq "proxy_pass http://127.0.0.1:$CF_XRAY_PORT;" "$NGINX_SITE" || die 'nginx site does not forward to Xray'
  local name
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    ! grep -Eq "server_name[^;]*[[:space:]]${name//./\\.}([[:space:];]|$)" "$NGINX_SITE" \
      || die 'nginx site unexpectedly contains an existing direct hostname'
  done < <(direct_hostnames)
  log 'verification passed'
}

subscription_candidate_path() {
  local file=''
  if [[ -n $SUBSCRIPTION_FILE ]]; then
    file=$SUBSCRIPTION_FILE
  elif [[ -f $REALITY_STATE && ! -L $REALITY_STATE ]]; then
    file=$(awk -F= '$1 == "SUBSCRIPTION_FILE" {print substr($0, index($0, "=") + 1); exit}' "$REALITY_STATE")
    file=${file#\"}; file=${file%\"}
    file=${file#\'}; file=${file%\'}
  fi
  printf '%s\n' "$file"
}

rollback_overlay() {
  ((ASSUME_YES == 1)) || die 'rollback requires --yes'
  require_root
  exec 9>/run/lock/edge-infra-cloudflare.lock
  flock -n 9 || die 'another Cloudflare overlay operation is running'
  [[ -f $STATE_FILE ]] || die 'Cloudflare overlay is not installed'
  [[ ! -e $STATE_DIR/subscription-transaction.env ]] \
    || die 'a subscription publication is pending; accept or roll it back first'
  local subscription
  subscription=$(subscription_candidate_path)
  if [[ -n $subscription ]]; then
    [[ -f $subscription && ! -L $subscription ]] || die 'subscription file is invalid'
    ! grep -Fq -- '- name: DediOne-Cloudflare' "$subscription" \
      || die 'remove DediOne-Cloudflare from the subscription before removing the overlay'
  fi

  local backup
  backup=$BACKUP_ROOT/rollback-$(date -u +%Y%m%dT%H%M%SZ)
  install -d -m 0700 "$BACKUP_ROOT" "$backup"
  cp -p "$STATE_FILE" "$backup/state.env"
  [[ ! -f $STATE_DIR/uuid ]] || cp -p "$STATE_DIR/uuid" "$backup/uuid"

  systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_PATH" "$NGINX_LINK" "$NGINX_SITE"
  systemctl daemon-reload
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx.service >/dev/null 2>&1 || true
  else
    warn 'nginx configuration is invalid after removing the overlay; inspect before reloading'
  fi
  rm -rf -- "$ETC" "$LIB" "$STATE_DIR"
  log "rollback complete; private state backup retained at $backup"
}

main() {
  local command=${1:-}
  (($# == 0)) || shift
  parse_options "$@"
  case "$command" in
    preflight) preflight ;;
    install) install_overlay ;;
    status) status_overlay ;;
    verify) require_root; verify_internal ;;
    rollback) rollback_overlay ;;
    *) usage; die "unknown command: ${command:-}" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
