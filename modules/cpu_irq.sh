#!/usr/bin/env bash
set -Eeuo pipefail

module_cpu_irq_enable_irqbalance() {
  header
  section "Install & enable irqbalance"
  local d
  d="$(backup_create "cpu_irq:irqbalance")"

  run_step "Updating package index" apt-get update -y || true
  if ! dpkg -s irqbalance >/dev/null 2>&1; then
    run_step "Installing irqbalance" apt-get install -y irqbalance || true
    if dpkg -s irqbalance >/dev/null 2>&1; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      touch "$STATE_DIR/installed_irqbalance.marker" 2>/dev/null || true
    fi
  fi
  run_step "Enabling irqbalance service" systemctl enable --now irqbalance || true

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    ok "irqbalance is active. (Backup: $d)"
  else
    warn "irqbalance may not be active on this system."
  fi
  pause
}

hex_mask_all_cpus() {
  local n="$1"
  python3 - "$n" <<'PY'
import sys
n=int(sys.argv[1])
print(format((1<<n)-1, 'x'))
PY
}

module_cpu_irq_apply_rps() {
  header
  section "Apply RPS/RFS/XPS"
  local d
  d="$(backup_create "cpu_irq:rps_rfs_xps")"

  local nic cpus mask
  nic="$(detect_nic)"
  cpus="$(nproc)"
  mask="$(hex_mask_all_cpus "$cpus")"

  info "NIC: $nic | CPUs: $cpus | Mask: $mask"

  # Persist RPS sysctl across reboot
  tee /etc/sysctl.d/99-sso-rps.conf >/dev/null <<'EOF'
# SSO: RPS/RFS global settings
net.core.rps_sock_flow_entries=65536
EOF
  run_step "Applying sysctl settings" sysctl --system || warn "sysctl apply had errors (continuing)."

  # Create a restore script for queue settings (non-persistent sysfs)
  ensure_dirs /usr/local/sbin
  cat > /usr/local/sbin/sso-cpuirq-restore <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/utils.sh"

nic="$(detect_nic)"
cpus="$(nproc)"
mask="$(python3 - <<PY
import os
n=int(os.popen("nproc").read().strip() or "1")
print(format((1<<n)-1, 'x'))
PY
)"

# Apply persisted sysctl just in case
  run_step "Setting rps_sock_flow_entries" sysctl -w net.core.rps_sock_flow_entries=65536 || warn "Could not set rps_sock_flow_entries (continuing)."

for f in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
  [[ -f "$f" ]] || continue
  echo "$mask" > "$f" || true
done
for f in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
  [[ -f "$f" ]] || continue
  echo 4096 > "$f" || true
done
_xps_any=false
_xps_failed=false
for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
  [[ -e "$f" ]] || continue
  _xps_any=true
  if ! echo "$mask" > "$f" 2>/dev/null; then
    _xps_failed=true
  fi
done

if [[ "$_xps_any" == true && "$_xps_failed" == true ]]; then
  warn "XPS: kernel/driver rejected writing xps_cpus (common on virtio single-queue)."
fi
EOS
  chmod +x /usr/local/sbin/sso-cpuirq-restore

  # systemd unit for persistence
  cat > /etc/systemd/system/sso-cpuirq.service <<'EOF'
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
EOF

  run_step "Reloading systemd units" systemctl daemon-reload || warn "systemd daemon-reload failed (continuing)."
  run_step "Enabling SSO CPU/IRQ service" systemctl enable --now sso-cpuirq.service || warn "Could not enable sso-cpuirq.service (continuing)."



  # RFS global table
  run_step "Setting rps_sock_flow_entries" sysctl -w net.core.rps_sock_flow_entries=65536 || warn "Could not set rps_sock_flow_entries (continuing)."

  info "Applying per-queue RPS/RFS/XPS settings..." 

  # Per RX queue
  for f in /sys/class/net/"$nic"/queues/rx-*/rps_cpus; do
    [[ -f "$f" ]] || continue
    echo "$mask" > "$f" || true
  done
  for f in /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt; do
    [[ -f "$f" ]] || continue
    echo 16384 > "$f" || true
  done

  # XPS for TX queues
  local xps_any=false xps_failed=false
  for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
    [[ -e "$f" ]] || continue
    xps_any=true
    if ! echo "$mask" > "$f" 2>/dev/null; then
      xps_failed=true
    fi
  done

  if [[ "$xps_any" == false ]]; then
    info "XPS: no TX queues found (nothing to apply)."
  elif [[ "$xps_failed" == true ]]; then
    warn "XPS: kernel/driver rejected writing xps_cpus (common on virtio single-queue). XPS skipped."
  else
    ok "XPS: applied successfully."
  fi

  ok "Applied RPS/RFS/XPS. (Backup: $d)"
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
    # Fast path: show values when readable
    if ! grep -H . /sys/class/net/"$nic"/queues/tx-*/xps_cpus 2>/dev/null; then
      # If read fails (sysfs can return ENOENT/EIO), show a clear message.
      local f
      for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
        [[ -e "$f" ]] || continue
        if ! cat "$f" >/dev/null 2>&1; then
          warn "XPS: present but not readable ($f). This is usually a driver/VM limitation; not a script error."
        fi
      done
    fi
  else
    info "XPS: no TX queues/xps_cpus found."
  fi
  pause
}
