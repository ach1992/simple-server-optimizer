#!/usr/bin/env bash
set -Eeuo pipefail

module_network_enable_fq_bbr() {
  header
  section "Enable fq + BBR"
  local d
  d="$(backup_create "network:fq_bbr")"

  tee /etc/sysctl.d/99-sso-qdisc.conf >/dev/null <<'EOF'
net.core.default_qdisc=fq
EOF

  run_step "Loading tcp_bbr kernel module" modprobe tcp_bbr || warn "Could not load tcp_bbr (it may be built-in or unavailable)."

  local avail bbr_available=0 persistence_warning=0
  avail="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if echo "$avail" | grep -qw bbr; then
    bbr_available=1

    # This legacy shared file may already contain operator entries. Preserve
    # those entries and add tcp_bbr only when needed instead of overwriting it.
    if [[ -e /etc/modules-load.d/bbr.conf || -L /etc/modules-load.d/bbr.conf ]]; then
      if [[ -f /etc/modules-load.d/bbr.conf && ! -L /etc/modules-load.d/bbr.conf ]]; then
        if ! grep -qxF 'tcp_bbr' /etc/modules-load.d/bbr.conf 2>/dev/null; then
          printf '%s\n' 'tcp_bbr' >> /etc/modules-load.d/bbr.conf || persistence_warning=1
        fi
      else
        warn "/etc/modules-load.d/bbr.conf is not a normal file; leaving it unchanged."
        persistence_warning=1
      fi
    else
      printf '%s\n' 'tcp_bbr' > /etc/modules-load.d/bbr.conf || persistence_warning=1
    fi

    tee /etc/sysctl.d/99-sso-bbr.conf >/dev/null <<'EOF'
net.ipv4.tcp_congestion_control=bbr
EOF
    info "BBR is available; configuration was prepared."
  else
    warn "BBR is not available on this kernel. Keeping the current congestion control."
    rm -f /etc/sysctl.d/99-sso-bbr.conf 2>/dev/null || true
  fi

  local apply_failed=0
  if ! run_step "Applying sysctl settings" sysctl --system; then
    apply_failed=1
    warn "sysctl reported errors; some runtime settings may not have been applied."
  fi

  local current_cc
  current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")"
  if [[ "$bbr_available" -eq 1 && "$current_cc" == "bbr" ]]; then
    ok "BBR is active."
  elif [[ "$bbr_available" -eq 1 ]]; then
    warn "BBR is available but is not active (current: $current_cc)."
    apply_failed=1
  fi

  if [[ "$persistence_warning" -eq 1 ]]; then
    warn "BBR module-load persistence could not be fully prepared; current runtime may still work."
  fi

  if [[ "$apply_failed" -eq 0 && "$persistence_warning" -eq 0 ]]; then
    ok "Network settings applied. (Backup: $d)"
  else
    warn "Network configuration finished with warnings. Review the status below. (Backup: $d)"
  fi
  module_network_show
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

  if run_step "Applying sysctl settings" sysctl --system; then
    ok "TCP tuning applied. (Backup: $d)"
  else
    warn "TCP tuning file was saved, but sysctl reported errors; runtime application may be partial. (Backup: $d)"
  fi
  module_network_show
}

module_network_show() {
  header
  section "Current network settings"
  tcp_info
  echo ""
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")"
  if [[ "$cc" == "bbr" ]]; then
    ok "BBR is ACTIVE."
  else
    warn "BBR is NOT active (current: $cc)."
  fi
  info "Effective sysctl (SSO files):"
  ls -1 /etc/sysctl.d/99-sso-*.conf 2>/dev/null | sed 's/^/ - /' || true
  echo ""
  local nic
  nic="$(detect_nic)"
  info "qdisc ($nic):"
  tc qdisc show dev "$nic" 2>/dev/null || true
  pause
}
