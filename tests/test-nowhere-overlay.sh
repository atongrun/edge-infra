#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script=$repo_root/scripts/nowhere-overlay.sh

bash -n "$script"
grep -Fq 'VERSION=v3.0.1' "$script"
grep -Fq '261ceaa63f34915f6fa62545d59d75e9a8876112fe5b6c7f47897c7a818b82ea' "$script"
grep -Fq '93704f0d0116e8332b50c21dc0d9b1c13e12f40b5bc6608e805be11cba5f9a87' "$script"
grep -Fq 'NOWHERE_TRANSPORT_MEMORY_PROFILE=memory' "$repo_root/env/nowhere.env.example"
grep -Fq 'User=edge-nowhere' "$repo_root/templates/systemd/edge-infra-nowhere.service"
grep -Fq 'NOWHERE_SERVICE_URL' "$repo_root/templates/systemd/edge-infra-nowhere.service"
grep -Fq 'RuntimeDirectory=edge-infra-nowhere' "$repo_root/templates/systemd/edge-infra-nowhere.service"
grep -Fq 'MemoryMax=128M' "$repo_root/templates/systemd/edge-infra-nowhere.service"
grep -Fq 'verify_manifest || die' "$script"
grep -Fq 'Upstream Nowhere takes its service URL on argv' "$repo_root/docs/nowhere.md"

tmpdir=$(mktemp -d /tmp/edge-infra-nowhere-test.XXXXXX)
trap 'rm -rf -- "$tmpdir"' EXIT
EDGE_INFRA_NOWHERE_SOURCE_ONLY=1 source "$script"
require_root() { :; }
STATE_DIR=$tmpdir/state; STATE_FILE=$STATE_DIR/state.env
BACKUP_ROOT=$tmpdir/backups; BACKUP_DIR=$BACKUP_ROOT/one
CONFIG_DIR=$tmpdir/config; RUNTIME_ENV=$CONFIG_DIR/runtime.env; CERT_DIR=$CONFIG_DIR/certs
BIN_DIR=$tmpdir/bin; BIN_PATH=$BIN_DIR/nowhere; UNIT_PATH=$tmpdir/unit; CLI_PATH=$tmpdir/cli; HOOK_PATH=$tmpdir/hook
NOWHERE_TCP_PORT=10443; NOWHERE_UDP_PORT=10443; NOWHERE_PUBLIC_HOST=relay.example.com; NOWHERE_CERT_NAME=relay.example.com
NOWHERE_ASSET=nowhere-test; NOWHERE_SHA256=deadbeef; UFW_TCP=0; UFW_UDP=0
mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$CERT_DIR" "$BIN_DIR"
for file in "$BIN_PATH" "$UNIT_PATH" "$CLI_PATH" "$RUNTIME_ENV" "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" "$HOOK_PATH"; do printf x > "$file"; done
cat > "$STATE_FILE" <<EOF
BACKUP_DIR=$BACKUP_DIR
NOWHERE_PUBLIC_HOST=$NOWHERE_PUBLIC_HOST
NOWHERE_CERT_NAME=$NOWHERE_CERT_NAME
NOWHERE_TCP_PORT=$NOWHERE_TCP_PORT
NOWHERE_UDP_PORT=$NOWHERE_UDP_PORT
NOWHERE_ASSET=$NOWHERE_ASSET
NOWHERE_SHA256=$NOWHERE_SHA256
UFW_TCP=0
UFW_UDP=0
EOF
write_manifest
printf changed >> "$RUNTIME_ENV"
calls=$tmpdir/calls
systemctl() { printf '%s\n' "$*" >> "$calls"; return 0; }
ASSUME_YES=1; FORCE=0
if (rollback) >/dev/null 2>&1; then echo 'rollback accepted changed owned file' >&2; exit 1; fi
[[ ! -e $calls ]] || { echo 'rollback touched systemctl before rejecting manifest' >&2; exit 1; }
[[ -f $RUNTIME_ENV ]] || { echo 'rollback removed changed owned file' >&2; exit 1; }

FORCE=1
systemctl() { printf '%s\n' "$*" >> "$calls"; [[ $1 == is-active ]] && return 3; return 0; }
tcp_port_in_use() { return 1; }; udp_port_in_use() { return 1; }
rollback
[[ -f $BACKUP_DIR/removed-overlay/archive-files.sha256 ]] || { echo 'rollback did not retain recovery archive' >&2; exit 1; }
[[ ! -e $RUNTIME_ENV && ! -e $STATE_FILE ]] || { echo 'forced rollback did not remove owned paths' >&2; exit 1; }

# Renewal must use restart and fail when the restarted service remains inactive.
mkdir -p "$STATE_DIR" "$BACKUP_DIR"
cat > "$STATE_FILE" <<EOF
BACKUP_DIR=$BACKUP_DIR
NOWHERE_CERT_NAME=$NOWHERE_CERT_NAME
NOWHERE_TCP_PORT=$NOWHERE_TCP_PORT
NOWHERE_UDP_PORT=$NOWHERE_UDP_PORT
EOF
verify_manifest() { return 0; }; stage_certificates() { PREVIOUS_CERT_DIR=''; }
restore_previous_cert() { :; }; verify() { :; }; wait_for_listener() { return 0; }
systemctl() { printf '%s\n' "$*" >> "$calls"; [[ $1 == is-active ]] && return 3; return 0; }
if (renew) >/dev/null 2>&1; then echo 'renew accepted inactive service' >&2; exit 1; fi
grep -q '^restart edge-infra-nowhere.service$' "$calls" || { echo 'renew did not use systemctl restart' >&2; exit 1; }
echo 'test-nowhere-overlay: passed'
