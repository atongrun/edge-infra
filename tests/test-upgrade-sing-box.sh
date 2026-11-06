#!/usr/bin/env bash
set -Eeuo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d /tmp/edge-upgrade-test.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
# shellcheck source=../scripts/upgrade-sing-box.sh
source "$root/scripts/upgrade-sing-box.sh"
require_root() { :; }
STATE=$tmp/state; BIN=$tmp/sing-box; BACKUPS=$tmp/backups
mkdir -p "$STATE"
if (preflight) >"$tmp/out" 2>&1; then echo 'accepted pending transaction' >&2; exit 1; fi
grep -q 'pending transaction' "$tmp/out"
mkdir -p "$BACKUPS/upgrade.test123"
printf '#!/bin/sh\nexit 0\n' > "$BACKUPS/upgrade.test123/rollback.sh"
chmod +x "$BACKUPS/upgrade.test123/rollback.sh"
printf '%s\n' "$BACKUPS/upgrade.test123" > "$STATE/backup"
printf '%s\n' edge-infra-upgrade-rollback-test123 > "$STATE/timer"
touch "$BACKUPS/upgrade.test123/rolled-back"
systemctl() { touch "$tmp/systemctl-called"; }
if (finish_upgrade commit) >"$tmp/out" 2>&1; then echo 'committed after automatic rollback' >&2; exit 1; fi
grep -q 'automatic rollback already ran' "$tmp/out"
[[ ! -e $tmp/systemctl-called && -d $STATE ]]
echo 'test-upgrade-sing-box: passed'
