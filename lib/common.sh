#!/usr/bin/env bash

log() {
  printf '[edge-infra] %s\n' "$*"
}

warn() {
  printf '[edge-infra] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[edge-infra] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

valid_domain() {
  local value=$1
  [[ ${#value} -le 253 ]] || return 1
  [[ $value =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_ipv4() {
  local value=$1 part
  local -a parts
  IFS=. read -r -a parts <<<"$value"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ $part =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
}

valid_email() {
  [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_filename() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] && [[ $1 != .* ]]
}

load_config() {
  local file=$1 line key value seen_keys=' '
  [[ -f $file ]] || die "config file not found: $file"
  [[ ! -L $file ]] || die "config file must not be a symlink: $file"

  EDGE_DOMAIN=''
  SUB_DOMAIN=''
  PUBLIC_IPV4=''
  ACME_EMAIL=''
  HOP_PORT_START=20000
  HOP_PORT_END=20031
  TROJAN_PORT=8443
  SUBSCRIPTION_FILE=''
  FIREWALL_MODE=auto
  NETWORK_INTERFACE=''

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die "invalid config line (expected KEY=VALUE): $line"
    key=${line%%=*}
    value=${line#*=}
    [[ $key =~ ^[A-Z0-9_]+$ ]] || die "invalid config key: $key"
    [[ $seen_keys != *" $key "* ]] || die "duplicate config key: $key"
    seen_keys+="$key "
    case "$key" in
      EDGE_DOMAIN) EDGE_DOMAIN=$value ;;
      SUB_DOMAIN) SUB_DOMAIN=$value ;;
      PUBLIC_IPV4) PUBLIC_IPV4=$value ;;
      ACME_EMAIL) ACME_EMAIL=$value ;;
      HOP_PORT_START) HOP_PORT_START=$value ;;
      HOP_PORT_END) HOP_PORT_END=$value ;;
      TROJAN_PORT) TROJAN_PORT=$value ;;
      FIREWALL_MODE) FIREWALL_MODE=$value ;;
      NETWORK_INTERFACE) NETWORK_INTERFACE=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$file"

  valid_domain "$EDGE_DOMAIN" || die "EDGE_DOMAIN must be a valid FQDN"
  valid_domain "$SUB_DOMAIN" || die "SUB_DOMAIN must be a valid FQDN"
  [[ $EDGE_DOMAIN != "$SUB_DOMAIN" ]] || die "EDGE_DOMAIN and SUB_DOMAIN must differ"
  valid_ipv4 "$PUBLIC_IPV4" || die "PUBLIC_IPV4 must be a valid IPv4 address"
  valid_email "$ACME_EMAIL" || die "ACME_EMAIL must be valid"
  valid_port "$HOP_PORT_START" || die "HOP_PORT_START must be a valid port"
  valid_port "$HOP_PORT_END" || die "HOP_PORT_END must be a valid port"
  (( 10#$HOP_PORT_START >= 1024 )) || die "HOP_PORT_START must be >= 1024"
  (( 10#$HOP_PORT_START <= 10#$HOP_PORT_END )) || die "HOP_PORT_START must be <= HOP_PORT_END"
  (( 10#$HOP_PORT_END - 10#$HOP_PORT_START + 1 <= 64 )) || die "port hopping range must contain at most 64 ports"
  valid_port "$TROJAN_PORT" || die "TROJAN_PORT must be a valid port"
  (( 10#$TROJAN_PORT >= 1024 )) || die "TROJAN_PORT must be >= 1024"
  [[ $FIREWALL_MODE == auto || $FIREWALL_MODE == none ]] || die "FIREWALL_MODE must be auto or none"
  if [[ -n $NETWORK_INTERFACE ]]; then
    [[ $NETWORK_INTERFACE =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] || die "NETWORK_INTERFACE is invalid"
  fi
}

load_secrets() {
  local file=$1 line key value
  [[ -f $file ]] || die "secrets file not found: $file"
  [[ ! -L $file ]] || die "secrets file must not be a symlink"
  HY2_PASSWORD=''
  TROJAN_PASSWORD=''
  SUBSCRIPTION_TOKEN=''
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      HY2_PASSWORD) HY2_PASSWORD=$value ;;
      TROJAN_PASSWORD) TROJAN_PASSWORD=$value ;;
      SUBSCRIPTION_TOKEN) SUBSCRIPTION_TOKEN=$value ;;
      *) die "unknown key in secrets file: $key" ;;
    esac
  done < "$file"
  [[ $HY2_PASSWORD =~ ^[a-f0-9]{64}$ ]] || die "HY2_PASSWORD is not a 64-character lowercase hex secret"
  [[ $TROJAN_PASSWORD =~ ^[a-f0-9]{64}$ ]] || die "TROJAN_PASSWORD is not a 64-character lowercase hex secret"
  [[ $SUBSCRIPTION_TOKEN =~ ^[a-f0-9]{48}$ ]] || die "SUBSCRIPTION_TOKEN is not a 48-character lowercase hex token"
  SUBSCRIPTION_FILE="$SUBSCRIPTION_TOKEN.yaml"
}

render_template() {
  local input=$1 output=$2 content
  [[ -f $input ]] || die "template not found: $input"
  content=$(<"$input")
  content=${content//\$\{EDGE_DOMAIN\}/$EDGE_DOMAIN}
  content=${content//\$\{SUB_DOMAIN\}/$SUB_DOMAIN}
  content=${content//\$\{PUBLIC_IPV4\}/$PUBLIC_IPV4}
  content=${content//\$\{ACME_EMAIL\}/$ACME_EMAIL}
  content=${content//\$\{HOP_PORT_START\}/$HOP_PORT_START}
  content=${content//\$\{HOP_PORT_END\}/$HOP_PORT_END}
  content=${content//\$\{TROJAN_PORT\}/$TROJAN_PORT}
  content=${content//\$\{SUBSCRIPTION_FILE\}/$SUBSCRIPTION_FILE}
  content=${content//\$\{NETWORK_INTERFACE\}/$NETWORK_INTERFACE}
  content=${content//\$\{CERT_NAME\}/$EDGE_DOMAIN}
  content=${content//\$\{HY2_PASSWORD\}/${HY2_PASSWORD:-\$\{HY2_PASSWORD\}}}
  content=${content//\$\{TROJAN_PASSWORD\}/${TROJAN_PASSWORD:-\$\{TROJAN_PASSWORD\}}}
  if [[ $content =~ \$\{[A-Z0-9_]+\} ]]; then
    die "unresolved placeholder in template: $input"
  fi
  mkdir -p "$(dirname -- "$output")"
  install -m 0600 /dev/null "$output"
  printf '%s\n' "$content" > "$output"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
