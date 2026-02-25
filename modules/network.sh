#!/usr/bin/env bash
set -Eeuo pipefail

module_network_enable_fq_bbr() {
  header
  section "Enable fq + BBR"
  local d
  d="$(backup_create "network:fq_bbr")"

  # fq default
  tee /etc/sysctl.d/99-sso-qdisc.conf >/dev/null <<'EOF'
net.core.default_qdisc=fq
EOF

  # try enable bbr if available
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/bbr.conf

  local avail
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo "$avail" | grep -qw bbr; then
    tee /etc/sysctl.d/99-sso-bbr.conf >/dev/null <<'EOF'
net.ipv4.tcp_congestion_control=bbr
EOF
    ok "BBR enabled."
  else
    warn "BBR not available on this kernel. Keeping default congestion control."
    rm -f /etc/sysctl.d/99-sso-bbr.conf 2>/dev/null || true
  fi

  sysctl --system >/dev/null 2>&1 || true
  ok "Applied. (Backup: $d)"
  module_network_show
  pause
}

module_network_apply_sysctl() {
  header
  section "Apply safe TCP tuning"
  local d
  d="$(backup_create "network:tcp_sysctl")"

  tee /etc/sysctl.d/99-sso-net-tuning.conf >/dev/null <<'EOF'
# Safe defaults for high connection count servers

net.core.somaxconn=8192
net.core.netdev_max_backlog=32768
net.ipv4.tcp_max_syn_backlog=16384

net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=200000

net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5

net.ipv4.ip_local_port_range=10240 65535
EOF

  sysctl --system >/dev/null 2>&1 || true
  ok "Applied safe TCP sysctl. (Backup: $d)"
  module_network_show
  pause
}

module_network_show() {
  header
  section "Current network settings"
  tcp_info
  echo ""
  info "Effective sysctl (SSO files):"
  ls -1 /etc/sysctl.d/99-sso-*.conf 2>/dev/null | sed 's/^/ - /' || true
  echo ""
  local nic
  nic="$(detect_nic)"
  info "qdisc ($nic):"
  tc qdisc show dev "$nic" 2>/dev/null || true
}
