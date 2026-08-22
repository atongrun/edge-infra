#!/usr/bin/env bash
# Interactive one-key installer for edge-infra.
#
# Prompts for the minimal public inputs, then runs the base installer and the
# Reality overlay so the finished host matches the live la-vps topology:
#   主链路 fallback: Reality -> Trojan -> HY2 -> HY2-Hop
#
# Run from a reviewed checkout:
#   git clone https://github.com/atongrun/edge-infra.git
#   cd edge-infra && git checkout <release-tag>
#   sudo ./install.sh
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

[[ $(id -u) -eq 0 ]] || { echo 'install.sh: must run as root (sudo ./install.sh)' >&2; exit 1; }

BASE_CLI=$SCRIPT_DIR/bin/edge-infra
OVERLAY=$SCRIPT_DIR/scripts/reality-overlay.sh
INSTALL_ENV=/root/edge-infra-install.env
REALITY_ENV=/root/edge-infra-reality.env
STATE_FILE=/var/lib/edge-infra/state.env

log()  { printf '[edge-infra] %s\n' "$*"; }
warn() { printf '[edge-infra] WARNING: %s\n' "$*" >&2; }
die()  { printf '[edge-infra] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- input helpers ----------
valid_domain() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; }
valid_ipv4() {
  local -a p; IFS=. read -r -a p <<<"$1"; [[ ${#p[@]} -eq 4 ]] || return 1
  for i in "${p[@]}"; do [[ $i =~ ^[0-9]{1,3}$ ]] && ((10#$i <= 255)) || return 1; done
}
valid_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }

prompt() { # prompt <var> <label> <default-or-empty>
  local var=$1 label=$2 default=${3:-} value
  while :; do
    if [[ -n $default ]]; then
      read -r -p "$label [$default]: " value
      value=${value:-$default}
    else
      read -r -p "$label: " value
    fi
    [[ -n $value ]] || { echo '  value is required'; continue; }
    printf -v "$var" '%s' "$value"
    return 0
  done
}

prompt_domain() { # prompt_domain <var> <label> <default-or-empty>
  local var=$1 label=$2 default=${3:-} value
  while :; do
    if [[ -n $default ]]; then
      read -r -p "$label [$default]: " value; value=${value:-$default}
    else
      read -r -p "$label: " value
    fi
    valid_domain "$value" && { printf -v "$var" '%s' "$value"; return 0; }
    echo '  enter a valid FQDN'
  done
}

detect_public_ipv4() {
  local iface addr
  iface=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
  [[ -n $iface ]] || return 1
  addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '$3=="inet"{split($4,a,"/"); print a[1]; exit}')
  [[ -n $addr ]] || return 1
  printf '%s\n' "$addr"
}

# ---------- gather inputs ----------
log 'edge-infra one-key install'
log 'final topology: Reality -> Trojan -> HY2 -> HY2-Hop (主链路 fallback)'
echo

EDGE_DOMAIN=''; SUB_DOMAIN=''; PUBLIC_IPV4=''; ACME_EMAIL=''
REALITY_PORT='9443'; REALITY_TARGET='dl.google.com'; REALITY_SERVER_NAME=''

prompt_domain EDGE_DOMAIN 'Edge domain (proxy + ACME cert)'
prompt_domain SUB_DOMAIN  'Subscription domain (HTTPS sub)'

detected_ip=$(detect_public_ipv4 || true)
if valid_ipv4 "$detected_ip"; then
  prompt PUBLIC_IPV4 'VPS public IPv4' "$detected_ip"
else
  prompt PUBLIC_IPV4 'VPS public IPv4' ''
fi
valid_ipv4 "$PUBLIC_IPV4" || die 'invalid IPv4'

while :; do
  prompt ACME_EMAIL 'ACME email (Let'"'"'s Encrypt)' ''
  valid_email "$ACME_EMAIL" && break
  echo '  enter a valid email'
done

echo
log 'Reality overlay inputs (VLESS + Reality + Vision, TCP-stable front candidate)'
prompt REALITY_PORT 'Reality TCP port' '9443'
valid_port "$REALITY_PORT" || die 'invalid Reality port'
prompt_domain REALITY_TARGET 'Reality target (must serve TLS 1.3 + h2 + valid cert)' 'dl.google.com'
prompt_domain REALITY_SERVER_NAME 'Reality SNI / server_name' "$REALITY_TARGET"

echo
log 'Review:'
printf '  %-22s %s\n' EDGE_DOMAIN "$EDGE_DOMAIN" SUB_DOMAIN "$SUB_DOMAIN" PUBLIC_IPV4 "$PUBLIC_IPV4" \
  ACME_EMAIL "$ACME_EMAIL" REALITY_PORT "$REALITY_PORT/tcp" REALITY_TARGET "$REALITY_TARGET" \
  REALITY_SERVER_NAME "$REALITY_SERVER_NAME"
echo
read -r -p 'Proceed with install? [y/N]: ' confirm
[[ $confirm =~ ^[Yy]$ ]] || die 'aborted'

# ---------- write configs ----------
umask 077
cat > "$INSTALL_ENV" <<EOF
EDGE_DOMAIN=$EDGE_DOMAIN
SUB_DOMAIN=$SUB_DOMAIN
PUBLIC_IPV4=$PUBLIC_IPV4
ACME_EMAIL=$ACME_EMAIL
EOF
log "wrote $INSTALL_ENV"

# Reality env is finalized after the base install, once the subscription path is known.
# ---------- base install ----------
log 'running base preflight'
"$BASE_CLI" preflight --config "$INSTALL_ENV"
log 'running base install'
"$BASE_CLI" install --config "$INSTALL_ENV" --yes

# ---------- resolve subscription path from state ----------
[[ -f $STATE_FILE ]] || die "base install finished but $STATE_FILE is missing"
# shellcheck disable=SC1090
source "$STATE_FILE"
[[ -n ${SUBSCRIPTION_FILE:-} ]] || die 'base state has no SUBSCRIPTION_FILE'
SUB_FULL_PATH=/var/www/edge-infra-subscription/$SUBSCRIPTION_FILE
[[ -f $SUB_FULL_PATH ]] || die "subscription file not found at $SUB_FULL_PATH"

cat > "$REALITY_ENV" <<EOF
REALITY_SERVER=$EDGE_DOMAIN
REALITY_PORT=$REALITY_PORT
REALITY_TARGET=$REALITY_TARGET
REALITY_SERVER_NAME=$REALITY_SERVER_NAME
SUBSCRIPTION_FILE=$SUB_FULL_PATH
EOF
log "wrote $REALITY_ENV"

# ---------- reality overlay ----------
log 'running Reality overlay preflight'
"$OVERLAY" preflight --config "$REALITY_ENV"
log 'running Reality overlay install'
"$OVERLAY" install --config "$REALITY_ENV" --yes

# ---------- report ----------
echo
log 'installation complete'
log "subscription URL: https://$SUB_DOMAIN/$SUBSCRIPTION_FILE"
log 'secrets: /etc/edge-infra/secrets.env (root-only, 0600)'
log 'next: import the subscription URL into Mihomo/Clash Verge and run an external smoke test'
log 'verify:  sudo edge-infra verify && sudo edge-infra-reality verify'
