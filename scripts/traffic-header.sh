#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

CONFIG_FILE=${EDGE_INFRA_TRAFFIC_CONFIG:-/etc/edge-infra/traffic.env}
[[ -r $CONFIG_FILE && ! -L $CONFIG_FILE ]] || {
  printf 'traffic config is missing or unsafe: %s\n' "$CONFIG_FILE" >&2
  exit 1
}
# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${NETWORK_INTERFACE:?NETWORK_INTERFACE is required}"
: "${TOTAL_BYTES:?TOTAL_BYTES is required}"
: "${SNIPPET_PATH:?SNIPPET_PATH is required}"
[[ $NETWORK_INTERFACE =~ ^[A-Za-z0-9_.:-]+$ ]] || { echo 'invalid NETWORK_INTERFACE' >&2; exit 1; }
[[ $TOTAL_BYTES =~ ^[1-9][0-9]*$ ]] || { echo 'invalid TOTAL_BYTES' >&2; exit 1; }
[[ $SNIPPET_PATH == /etc/nginx/snippets/edge-infra-traffic/subscription-userinfo.conf ]] \
  || { echo 'unsafe SNIPPET_PATH' >&2; exit 1; }

usage_bytes() {
  local year month json row
  year=$(date +%Y)
  month=$((10#$(date +%m)))
  json=$(vnstat --json m 1 -i "$NETWORK_INTERFACE")
  row=$(jq -er --argjson year "$year" --argjson month "$month" '
    .interfaces | if length == 1 then .[0] else error("expected one interface") end
    | .traffic.month
    | map(select(.date.year == $year and .date.month == $month))
    | if length == 0 then [0, 0] else (last | [.rx, .tx]) end
    | if all(.[]; type == "number" and . >= 0) then @tsv else error("invalid counters") end
  ' <<<"$json")
  printf '%s\n' "$row"
}

render_candidate() {
  local rx tx
  IFS=$'\t' read -r rx tx < <(usage_bytes)
  printf 'add_header Subscription-Userinfo "upload=%s; download=%s; total=%s" always;\n' \
    "$rx" "$tx" "$TOTAL_BYTES"
}

nginx_test() {
  local test_conf test_pid status=0
  [[ $(grep -Ec '^[[:space:]]*pid[[:space:]]' /etc/nginx/nginx.conf) == 1 ]] || {
    echo 'expected one nginx pid directive' >&2
    return 1
  }
  [[ $(grep -Ec '^[[:space:]]*error_log[[:space:]]' /etc/nginx/nginx.conf) == 1 ]] || {
    echo 'expected one nginx error_log directive' >&2
    return 1
  }
  test_conf=$(mktemp /tmp/edge-infra-nginx-conf.XXXXXX)
  test_pid=$(mktemp /tmp/edge-infra-nginx-pid.XXXXXX)
  rm -f "$test_pid"
  sed \
    -e "s#^[[:space:]]*pid[[:space:]].*#pid $test_pid;#" \
    -e 's#^[[:space:]]*error_log[[:space:]].*#error_log stderr;#' \
    /etc/nginx/nginx.conf > "$test_conf"
  nginx -t -c "$test_conf" || status=$?
  rm -f "$test_conf" "$test_pid"
  return "$status"
}

update_header() {
  local candidate rollback had_old=0
  candidate=$(mktemp "$SNIPPET_PATH.candidate.XXXXXX")
  rollback=$(mktemp "$SNIPPET_PATH.rollback.XXXXXX")
  trap 'rm -f "$candidate" "$rollback"' RETURN
  render_candidate > "$candidate"
  chmod 0644 "$candidate"
  if [[ -f $SNIPPET_PATH ]] && cmp -s "$candidate" "$SNIPPET_PATH"; then
    return 0
  fi
  if [[ -f $SNIPPET_PATH ]]; then
    cp -p "$SNIPPET_PATH" "$rollback"
    had_old=1
  fi
  install -m 0644 "$candidate" "$SNIPPET_PATH"
  if ! nginx_test; then
    if (( had_old == 1 )); then cp -p "$rollback" "$SNIPPET_PATH"; else rm -f "$SNIPPET_PATH"; fi
    nginx_test
    return 1
  fi
  if ! systemctl reload nginx.service; then
    if (( had_old == 1 )); then cp -p "$rollback" "$SNIPPET_PATH"; else rm -f "$SNIPPET_PATH"; fi
    nginx_test
    systemctl reload nginx.service
    return 1
  fi
}

verify_header() {
  local current_rx current_tx actual values upload download total
  [[ -f $SNIPPET_PATH ]] || { echo 'traffic header snippet is missing' >&2; exit 1; }
  IFS=$'\t' read -r current_rx current_tx < <(usage_bytes)
  actual=$(<"$SNIPPET_PATH")
  values=$(sed -nE \
    's/^add_header Subscription-Userinfo "upload=([0-9]+); download=([0-9]+); total=([0-9]+)" always;$/\1 \2 \3/p' \
    <<<"$actual")
  [[ -n $values ]] || { echo 'traffic header syntax is invalid' >&2; exit 1; }
  read -r upload download total <<<"$values"
  [[ $total == "$TOTAL_BYTES" ]] || { echo 'traffic header total is invalid' >&2; exit 1; }
  (( upload <= current_rx && download <= current_tx )) \
    || { echo 'traffic header counters exceed current vnStat month' >&2; exit 1; }
  nginx_test
  systemctl is-active --quiet nginx.service
  printf '%s\n' "$actual"
}

case "${1:-update}" in
  render) render_candidate ;;
  update) update_header ;;
  verify) verify_header ;;
  *) echo 'usage: edge-infra-traffic [render|update|verify]' >&2; exit 2 ;;
esac
