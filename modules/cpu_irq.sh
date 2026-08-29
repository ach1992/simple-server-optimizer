#!/usr/bin/env bash
set -Eeuo pipefail

RPS_SOCK_FLOW_ENTRIES=65536
RPS_FLOW_CNT=16384

module_cpu_irq_enable_irqbalance() {
  header
  section "Install & enable irqbalance"
  local d
  d="$(backup_create "cpu_irq:irqbalance")"

  run_step "Updating package index" apt-get update -y || warn "Package index update failed; trying with the current package cache."
  if ! dpkg -s irqbalance >/dev/null 2>&1; then
    if ! run_step "Installing irqbalance" apt-get install -y irqbalance; then
      err "Could not install irqbalance."
      pause
      return 0
    fi
    if dpkg -s irqbalance >/dev/null 2>&1; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      touch "$STATE_DIR/installed_irqbalance.marker" 2>/dev/null || true
    fi
  fi

  if ! run_step "Enabling irqbalance service" systemctl enable --now irqbalance; then
    warn "Could not enable/start irqbalance."
  fi

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    ok "irqbalance is active. (Backup: $d)"
  else
    warn "irqbalance is not active. Check systemctl status irqbalance. (Backup: $d)"
  fi
  pause
}

# Render an all-CPU Linux cpumask without depending on Python or another
# non-shell helper. Each comma-separated group represents up to 32 CPUs.
hex_mask_all_cpus() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n >= 1 )) || return 1

  local full_groups=$((n / 32))
  local remainder=$((n % 32))
  local i partial
  local -a parts=()

  if (( remainder > 0 )); then
    partial=$(( (1 << remainder) - 1 ))
    printf -v partial '%x' "$partial"
    parts+=("$partial")
  fi

  for ((i = 0; i < full_groups; i++)); do
    parts+=("ffffffff")
  done

  local IFS=,
  printf '%s\n' "${parts[*]}"
}

# RPS/RFS/XPS is a rollback-sensitive operation. Some VM/virtio drivers expose
# an xps_cpus sysfs entry that can be discovered/stat'ed but cannot actually be
# read. In that state backup_capture_cpu_runtime cannot certify a reversible
# baseline. Detect the exact queue path before backup creation so the menu can
# fail closed with an actionable explanation instead of exiting under set -e.
cpu_irq_preflight_queue_snapshot() {
  local nic="$1"
  local net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local f

  if [[ ! -d "$net_root/$nic/queues" ]]; then
    err "CPU queue state is unavailable for NIC $nic: $net_root/$nic/queues"
    warn "No RPS/RFS/XPS settings were changed."
    return 1
  fi

  for f in \
    "$net_root/$nic"/queues/rx-*/rps_cpus \
    "$net_root/$nic"/queues/rx-*/rps_flow_cnt \
    "$net_root/$nic"/queues/tx-*/xps_cpus; do
    [[ -e "$f" || -L "$f" ]] || continue
    if ! cat "$f" >/dev/null 2>&1; then
      err "Cannot read CPU queue state required for rollback: $f"
      warn "The NIC/driver exposes this queue control but does not provide a readable pre-change value."
      warn "No RPS/RFS/XPS settings were changed."
      return 1
    fi
  done

  return 0
}

module_cpu_irq_apply_rps() {
  header
  section "Apply RPS/RFS/XPS"

  local nic cpus mask d
  nic="$(detect_nic)"

  if ! cpu_irq_preflight_queue_snapshot "$nic"; then
    pause
    return 0
  fi

  if ! d="$(backup_create "cpu_irq:rps_rfs_xps")"; then
    err "Could not create a complete pre-change backup."
    warn "No RPS/RFS/XPS settings were changed."
    warn "Review the backup error above before retrying."
    pause
    return 0
  fi

  cpus="$(nproc)"
  if ! mask="$(hex_mask_all_cpus "$cpus")"; then
    err "Could not calculate a CPU mask for $cpus CPUs."
    pause
    return 0
  fi

  info "NIC: $nic | CPUs: $cpus | Mask: $mask"

  local runtime_failed=0 persistence_failed=0

  printf '# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=%s\n' \
    "$RPS_SOCK_FLOW_ENTRIES" > /etc/sysctl.d/99-sso-rps.conf
  if ! run_step "Applying sysctl settings" sysctl --system; then
    runtime_failed=1
    warn "sysctl reported errors; some global runtime settings may not have been applied."
  fi

  ensure_dirs /usr/local/sbin
  cat > /usr/local/sbin/sso-cpuirq-restore <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/utils.sh"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/cpu_irq.sh"

nic="$(detect_nic)"
cpus="$(nproc)"
mask="$(hex_mask_all_cpus "$cpus")"
queue_failed=false
global_failed=false

run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES" || {
  warn "Could not set rps_sock_flow_entries."
  global_failed=true
}

rps_any=false
rps_failed=false
for f in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
  [[ -f "$f" ]] || continue
  rps_any=true
  if ! printf '%s\n' "$mask" > "$f" 2>/dev/null; then
    rps_failed=true
    queue_failed=true
  fi
done

rfs_any=false
rfs_failed=false
for f in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
  [[ -f "$f" ]] || continue
  rfs_any=true
  if ! printf '%s\n' "$RPS_FLOW_CNT" > "$f" 2>/dev/null; then
    rfs_failed=true
    queue_failed=true
  fi
done

xps_any=false
xps_failed=false
for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
  [[ -e "$f" ]] || continue
  xps_any=true
  if ! printf '%s\n' "$mask" > "$f" 2>/dev/null; then
    xps_failed=true
    queue_failed=true
  fi
done

[[ "$rps_any" == true ]] || info "RPS: no RX queues found."
[[ "$rfs_any" == true ]] || info "RFS: no RX flow-count files found."
[[ "$xps_any" == true ]] || info "XPS: no TX queues found."
[[ "$rps_failed" == false ]] || warn "RPS: one or more queue writes were rejected."
[[ "$rfs_failed" == false ]] || warn "RFS: one or more queue writes were rejected."
[[ "$xps_failed" == false ]] || warn "XPS: one or more queue writes were rejected by the kernel/driver."

if [[ "$queue_failed" == true || "$global_failed" == true ]]; then
  warn "CPU queue restore was only partially applied."
  exit 1
fi
EOS

  if ! chmod 755 /usr/local/sbin/sso-cpuirq-restore; then
    persistence_failed=1
    warn "Could not make the CPU/IRQ restore helper executable."
  fi

  cat > /etc/systemd/system/sso-cpuirq.service <<'EOF_UNIT'
[Unit]
Description=SSO CPU/IRQ tuning (RPS/RFS/XPS)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sso-cpuirq-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

  if ! run_step "Reloading systemd units" systemctl daemon-reload; then
    persistence_failed=1
    warn "systemd daemon-reload failed."
  fi
  if ! run_step "Enabling SSO CPU/IRQ service" systemctl enable --now sso-cpuirq.service; then
    persistence_failed=1
    warn "Could not enable sso-cpuirq.service; reboot persistence is not confirmed."
  fi

  if ! run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES"; then
    runtime_failed=1
    warn "Could not set rps_sock_flow_entries."
  fi

  info "Applying per-queue RPS/RFS/XPS settings..."

  local queue_failed=false
  local rps_any=false rps_failed=false
  local rfs_any=false rfs_failed=false
  local xps_any=false xps_failed=false
  local f

  for f in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
    [[ -f "$f" ]] || continue
    rps_any=true
    if ! printf '%s\n' "$mask" > "$f" 2>/dev/null; then
      rps_failed=true
      queue_failed=true
    fi
  done

  for f in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
    [[ -f "$f" ]] || continue
    rfs_any=true
    if ! printf '%s\n' "$RPS_FLOW_CNT" > "$f" 2>/dev/null; then
      rfs_failed=true
      queue_failed=true
    fi
  done

  for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
    [[ -e "$f" ]] || continue
    xps_any=true
    if ! printf '%s\n' "$mask" > "$f" 2>/dev/null; then
      xps_failed=true
      queue_failed=true
    fi
  done

  if [[ "$rps_any" == false ]]; then
    info "RPS: no RX queues found (nothing to apply)."
  elif [[ "$rps_failed" == true ]]; then
    warn "RPS: one or more queue writes were rejected."
  else
    ok "RPS: applied successfully."
  fi

  if [[ "$rfs_any" == false ]]; then
    info "RFS: no RX flow-count files found (nothing to apply)."
  elif [[ "$rfs_failed" == true ]]; then
    warn "RFS: one or more queue writes were rejected."
  else
    ok "RFS: applied successfully."
  fi

  if [[ "$xps_any" == false ]]; then
    info "XPS: no TX queues found (nothing to apply)."
  elif [[ "$xps_failed" == true ]]; then
    warn "XPS: one or more queue writes were rejected by the kernel/driver."
  else
    ok "XPS: applied successfully."
  fi

  if [[ "$queue_failed" == true || "$runtime_failed" -ne 0 || "$persistence_failed" -ne 0 ]]; then
    warn "RPS/RFS/XPS finished with warnings; runtime and/or reboot persistence is only partially confirmed. (Backup: $d)"
  else
    ok "Applied supported RPS/RFS/XPS settings with reboot persistence. (Backup: $d)"
  fi
  module_cpu_irq_show
}

module_cpu_irq_show() {
  header
  section "IRQ/RPS status"
  local nic
  nic="$(detect_nic)"
  info "NIC: $nic"
  systemctl is-active irqbalance 2>/dev/null | sed 's/^/irqbalance: /' || true
  echo ""
  info "RPS:"
  grep -H . /sys/class/net/"$nic"/queues/rx-*/rps_cpus 2>/dev/null || true
  grep -H . /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt 2>/dev/null || true
  echo ""
  info "XPS:"
  if compgen -G "/sys/class/net/$nic/queues/tx-*/xps_cpus" >/dev/null; then
    if ! grep -H . /sys/class/net/"$nic"/queues/tx-*/xps_cpus 2>/dev/null; then
      local f
      for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
        [[ -e "$f" ]] || continue
        if ! cat "$f" >/dev/null 2>&1; then
          warn "Present but not readable ($f). This is usually a driver/VM limitation; not a script error."
        fi
      done
    fi
  else
    info "XPS: no TX queues/xps_cpus found."
  fi
  pause
}
