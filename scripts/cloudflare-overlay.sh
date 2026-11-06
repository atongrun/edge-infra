#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ETC=/etc/edge-infra-cloudflare
LIB=/usr/local/lib/edge-infra-cloudflare
STATE=/var/lib/edge-infra-cloudflare
UNIT=/etc/systemd/system
CONF=''; SUB=''; YES=0; INSTALLING=0; TMP=''; TIMER=edge-infra-cf-pilot-rollback
die() { echo "cloudflare-overlay: $*" >&2; exit 1; }
cleanup() {
  local rc=$?
  trap - EXIT
  if (( INSTALLING )); then
    systemctl stop "$TIMER.timer" >/dev/null 2>&1 || true
    systemctl disable --now edge-infra-cloudflared.service edge-infra-cf-ws.service >/dev/null 2>&1 || true
    rm -f "$UNIT/edge-infra-cloudflared.service" "$UNIT/edge-infra-cf-ws.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "$ETC" "$LIB" "$STATE"
  fi
  [[ -z $TMP ]] || rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
load_config() {
  [[ -f $CONF && ! -L $CONF ]] || die 'config must be a regular file'
  local line key value seen=' '
  CF_HOSTNAME=''; CF_ORIGIN_PORT=''; CF_WS_PATH=''; CF_CREDENTIALS_FILE=''; CF_TUNNEL_ID=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die 'malformed config line'
    key=${line%%=*}; value=${line#*=}
    [[ $seen != *" $key "* ]] || die 'duplicate config key'
    seen+="$key "
    case "$key" in
      CF_HOSTNAME) CF_HOSTNAME=$value;; CF_ORIGIN_PORT) CF_ORIGIN_PORT=$value;;
      CF_WS_PATH) CF_WS_PATH=$value;; CF_CREDENTIALS_FILE) CF_CREDENTIALS_FILE=$value;;
      CF_TUNNEL_ID) CF_TUNNEL_ID=$value;; *) die 'unknown config key';;
    esac
  done < "$CONF"
  [[ $CF_HOSTNAME =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ && ${#CF_HOSTNAME} -le 253 ]] || die 'invalid hostname'
  if ! [[ $CF_ORIGIN_PORT =~ ^[0-9]{4,5}$ ]] || ! ((10#$CF_ORIGIN_PORT >= 1024 && 10#$CF_ORIGIN_PORT <= 65535)); then die 'invalid port'; fi
  [[ $CF_WS_PATH =~ ^/[A-Za-z0-9/_-]{1,128}$ ]] || die 'invalid path'
  [[ $CF_TUNNEL_ID =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || die 'invalid tunnel ID'
  [[ $CF_CREDENTIALS_FILE == /* && -f $CF_CREDENTIALS_FILE && ! -L $CF_CREDENTIALS_FILE ]] || die 'invalid credential file'
  if [[ $(stat -c '%u' "$CF_CREDENTIALS_FILE") != 0 ]] || (( (8#$(stat -c '%a' "$CF_CREDENTIALS_FILE") & 077) != 0 )); then die 'credential file must be root-owned and private'; fi
  [[ $(jq -r '.TunnelID // empty' "$CF_CREDENTIALS_FILE") == "$CF_TUNNEL_ID" ]] || die 'credential and tunnel ID mismatch'
}
preflight() {
  (( EUID == 0 )) || die 'root required'
  for x in curl sha256sum tar jq ss systemctl flock systemd-run; do command -v "$x" >/dev/null || die "missing $x"; done
  load_config
  [[ ! -e $ETC && ! -e $LIB && ! -e $STATE && ! -e $UNIT/edge-infra-cloudflared.service && ! -e $UNIT/edge-infra-cf-ws.service ]] || die 'owned path already exists; inspect before install'
  ! ss -H -lnt | awk '{print $4}' | grep -Eq ":${CF_ORIGIN_PORT}$" || die 'origin port already occupied'
  [[ $(systemctl show -p LoadState --value edge-infra-cloudflared.service) == not-found ]] || die 'cloudflared unit already registered'
  [[ $(systemctl show -p LoadState --value edge-infra-cf-ws.service) == not-found ]] || die 'WS unit already registered'
  case $(uname -m) in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; *) die 'unsupported architecture';; esac
  echo 'preflight passed'
}
install_overlay() {
  ((YES)) || die 'install requires --yes'
  preflight
  # The manifest is repository-owned, not supplied by deployment input.
  # shellcheck disable=SC1091
  source "$ROOT/env/resilience-versions.env"
  local cfsha sbsha
  if [[ $ARCH == amd64 ]]; then cfsha=$CLOUDFLARED_AMD64_SHA256; sbsha=$CF_SING_BOX_AMD64_SHA256; else cfsha=$CLOUDFLARED_ARM64_SHA256; sbsha=$CF_SING_BOX_ARM64_SHA256; fi
  TMP=$(mktemp -d /tmp/edge-cf-install.XXXXXX)
  curl -fsSL --retry 2 "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-$ARCH" -o "$TMP/cloudflared"
  printf '%s  %s\n' "$cfsha" "$TMP/cloudflared" | sha256sum -c --status || die 'cloudflared checksum mismatch'
  curl -fsSL --retry 2 "https://github.com/SagerNet/sing-box/releases/download/v$CF_SING_BOX_VERSION/sing-box-$CF_SING_BOX_VERSION-linux-$ARCH.tar.gz" -o "$TMP/sing.tar.gz"
  printf '%s  %s\n' "$sbsha" "$TMP/sing.tar.gz" | sha256sum -c --status || die 'sing-box checksum mismatch'
  tar -xzf "$TMP/sing.tar.gz" -C "$TMP" "sing-box-$CF_SING_BOX_VERSION-linux-$ARCH/sing-box"
  local sb="$TMP/sing-box-$CF_SING_BOX_VERSION-linux-$ARCH/sing-box" uuid
  chmod 700 "$sb" "$TMP/cloudflared"
  uuid=$($sb generate uuid)
  jq -n --arg uuid "$uuid" --arg path "$CF_WS_PATH" --argjson port "$CF_ORIGIN_PORT" \
    '{log:{level:"info",timestamp:true},inbounds:[{type:"vless",tag:"cf-ws-in",listen:"127.0.0.1",listen_port:$port,users:[{name:"cloudflare",uuid:$uuid}],transport:{type:"ws",path:$path}}],outbounds:[{type:"direct",tag:"direct"}]}' > "$TMP/ws.json"
  "$sb" check -c "$TMP/ws.json"
  cat > "$TMP/config.yml" <<EOF
tunnel: $CF_TUNNEL_ID
credentials-file: /run/credentials/edge-infra-cloudflared.service/tunnel.json
ingress:
  - hostname: $CF_HOSTNAME
    service: http://127.0.0.1:$CF_ORIGIN_PORT
  - service: http_status:404
EOF
  "$TMP/cloudflared" tunnel --config "$TMP/config.yml" ingress validate >/dev/null
  INSTALLING=1
  install -d -m 0700 "$ETC" "$STATE"
  install -d -m 0755 "$LIB"
  install -m 0755 "$sb" "$LIB/sing-box"
  install -m 0755 "$TMP/cloudflared" "$LIB/cloudflared"
  install -m 0600 "$TMP/ws.json" "$ETC/ws.json"
  install -m 0600 "$CF_CREDENTIALS_FILE" "$ETC/tunnel.json"
  install -m 0600 "$TMP/config.yml" "$ETC/config.yml"
  printf '%s\n' "$uuid" > "$STATE/uuid"
  printf 'CF_ORIGIN_PORT=%q\nCF_HOSTNAME=%q\nCF_WS_PATH=%q\n' "$CF_ORIGIN_PORT" "$CF_HOSTNAME" "$CF_WS_PATH" > "$STATE/state.env"
  install -m 0644 "$ROOT/templates/systemd/edge-infra-cf-ws.service" "$UNIT/edge-infra-cf-ws.service"
  install -m 0644 "$ROOT/templates/systemd/edge-infra-cloudflared.service" "$UNIT/edge-infra-cloudflared.service"
  systemctl daemon-reload
  cat > "$STATE/pilot-rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl disable --now edge-infra-cloudflared.service edge-infra-cf-ws.service || true
rm -f /etc/systemd/system/edge-infra-cloudflared.service /etc/systemd/system/edge-infra-cf-ws.service
systemctl daemon-reload
rm -rf -- /etc/edge-infra-cloudflare /usr/local/lib/edge-infra-cloudflare /var/lib/edge-infra-cloudflare
EOF
  chmod 0700 "$STATE/pilot-rollback.sh"
  systemd-run --quiet --unit="$TIMER" --on-active=15m --timer-property=AccuracySec=1s /bin/bash "$STATE/pilot-rollback.sh" || die 'failed to arm pilot rollback'
  systemctl is-active --quiet "$TIMER.timer" || die 'pilot rollback timer is not active'
  systemctl enable --now edge-infra-cf-ws.service edge-infra-cloudflared.service || die 'service enable/start failed'
  for service in edge-infra-cf-ws.service edge-infra-cloudflared.service; do systemctl is-active --quiet "$service" || die 'service startup failed'; done
  local listening=0
  for _ in {1..40}; do
    if ss -H -lnt | awk '{print $4}' | grep -Eq "^127\\.0\\.0\\.1:${CF_ORIGIN_PORT}$"; then listening=1; break; fi
    sleep 0.25
  done
  ((listening)) || die 'loopback listener missing'
  INSTALLING=0
  echo 'services installed; pilot rollback is armed for 15 minutes; external client validation is required'
}
main() {
local command=${1:-}; shift || true
while (($#)); do case $1 in --config) CONF=${2:?}; shift 2;; --subscription) SUB=${2:?}; shift 2;; --yes) YES=1; shift;; *) die 'unknown option';; esac; done
exec 9>/run/lock/edge-infra-cloudflare.lock
flock -n 9 || die 'another operation is running'
case $command in
  preflight) preflight;;
  install) install_overlay;;
  status|verify) [[ -f $STATE/state.env ]] || die 'not installed'; systemctl is-active edge-infra-cf-ws.service edge-infra-cloudflared.service;;
  commit-pilot) ((YES)) || die 'commit-pilot requires --yes'; [[ -f $STATE/state.env ]] || die 'not installed'; systemctl is-active --quiet "$TIMER.timer" || die 'pilot timer is not active'; for service in edge-infra-cf-ws.service edge-infra-cloudflared.service; do systemctl is-active --quiet "$service" || die 'service inactive'; done; systemctl stop "$TIMER.timer"; ! systemctl is-active --quiet "$TIMER.service" || die 'rollback is running'; [[ -f $STATE/state.env ]] || die 'pilot rollback removed the installation'; echo 'pilot timer stopped; subscription publication remains separate';;
  rollback) ((YES)) || die 'rollback requires --yes'; [[ -f $STATE/state.env && -f $SUB && ! -L $SUB ]] || die 'provide existing --subscription file'; ! grep -Fq -- 'DediOne-Cloudflare' "$SUB" || die 'remove Cloudflare from subscription first'; INSTALLING=1; echo 'removing owned services on exit';;
  *) die 'usage: cloudflare-overlay.sh preflight|install --config FILE [--yes]; status|verify; rollback --subscription FILE --yes';;
esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
