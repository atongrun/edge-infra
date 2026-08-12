#!/bin/sh
set -eu

units="sing-box.service sing-box-trojan.service nginx.service hy2-port-hopping.service"
for unit in $units; do
  systemctl is-enabled "$unit"
  systemctl is-active "$unit"
done

/usr/local/bin/sing-box check -c /etc/sing-box/config.json
/usr/local/bin/sing-box check -c /etc/sing-box/trojan.json
nginx -t
ss -lntup | grep -E ':(22|443|8443)\b'
nft list table inet edge_hy2_port_hopping
ufw status verbose
nstat -az UdpRcvbufErrors UdpSndbufErrors
