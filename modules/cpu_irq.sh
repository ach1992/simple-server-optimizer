#!/usr/bin/env bash
set -Eeuo pipefail

RPS_SOCK_FLOW_ENTRIES=65536
RPS_FLOW_CNT=16384

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

n = int(sys.argv[1])
if n < 1:
    raise SystemExit(1)

value = (1 << n) - 1
parts = []
while value:
    parts.append(f"{value & 0xffffffff:08x}")
    value >>= 32
parts[-1] = parts[-1].lstrip("0") or "0"
print(",".join(reversed(parts)))
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

  printf '# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=%s\n' \
    "$RPS_SOCK_FLOW_ENTRIES" > /etc/sysctl.d/99-sso-rps.conf
  run_step "Applying sysctl settings" sysctl --system || warn "sysctl apply had errors (continuing)."

  ensure_dirs /usr/local/sbin
  cat > /usr/local/sbin/sso-cpuirq-restore <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/utils.sh"

RPS_SOCK_FLOW_ENTRIES=65536
RPS_FLOW_CNT=16384

hex_mask_all_cpus() {
  local n="$1"
  python3 - "$n" <<'PY'
import sys

n = int(sys.argv[1])
if n < 1:
    raise SystemExit(1)

value = (1 << n) - 1
parts = []
while value:
    parts.append(f"{value & 0xffffffff:08x}")
    value >>= 32
parts[-1] = parts[-1].lstrip("0") or "0"
print(",".join(reversed(parts)))
PY
}

nic="$(detect_nic)"
cpus="$(nproc)"
mask="$(hex_mask_all_cpus "$cpus")"
queue_failed=false

run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES" || warn "Could not set rps_sock_flow_entries (continuing)."

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

if [[ "$queue_failed" == true ]]; then
  warn "CPU queue restore was only partially applied; supported settings were kept."
fi
EOS
  chmod +x /usr/local/sbin/sso-cpuirq-restore

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

  run_step "Reloading systemd units" systemctl daemon-reload || warn "systemd daemon-reload failed (continuing)."
  run_step "Enabling SSO CPU/IRQ service" systemctl enable --now sso-cpuirq.service || warn "Could not enable sso-cpuirq.service (continuing)."

  run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES" || warn "Could not set rps_sock_flow_entries (continuing)."

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

  if [[ "$queue_failed" == true ]]; then
    warn "RPS/RFS/XPS was only partially applied; supported settings were kept. (Backup: $d)"
  else
    ok "Applied supported RPS/RFS/XPS settings. (Backup: $d)"
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
