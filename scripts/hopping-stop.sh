#!/bin/sh
set -eu

if /usr/sbin/nft list table inet edge_infra_hy2_hopping >/dev/null 2>&1; then
  /usr/sbin/nft delete table inet edge_infra_hy2_hopping
fi
