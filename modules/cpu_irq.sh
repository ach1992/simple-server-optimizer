#!/usr/bin/env bash
set -Eeuo pipefail

module_cpu_irq_enable_irqbalance() {
  header
  section "Install & enable irqbalance"
  local d
  d="$(backup_create "cpu_irq:irqbalance")"

  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y irqbalance >/dev/null 2>&1 || true
  systemctl enable --now irqbalance 2>/dev/null || true

  if systemctl is-active irqbalance >/dev/null 2>&1; then
    ok "irqbalance is active. (Backup: $d)"
  else
    warn "irqbalance may not be active on this system."
  fi
  pause
}

hex_mask_all_cpus() {
  local n="$1"
  python3 - <<PY
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

  # RFS global table
  sysctl -w net.core.rps_sock_flow_entries=65536 >/dev/null 2>&1 || true

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
  for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
    [[ -f "$f" ]] || continue
    echo "$mask" > "$f" || true
  done

  ok "Applied RPS/RFS/XPS. (Backup: $d)"
  module_cpu_irq_show
  pause
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
  grep -H . /sys/class/net/"$nic"/queues/tx-*/xps_cpus 2>/dev/null || true
}
