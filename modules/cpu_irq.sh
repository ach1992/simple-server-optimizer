#!/usr/bin/env bash
set -Eeuo pipefail

RPS_SOCK_FLOW_ENTRIES=65536
RPS_FLOW_CNT=16384

module_cpu_irq_enable_irqbalance() {
  header
  section "Install & enable irqbalance"
  local d
  if ! d="$(backup_create "cpu_irq:irqbalance")"; then
    err "Could not create a pre-change backup."
    pause
    return 0
  fi

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

hex_mask_all_cpus() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  (( n >= 1 )) || return 1

  local full_groups=$((n / 32)) remainder=$((n % 32)) i partial
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

cpu_irq_queue_value_is_valid() {
  local knob="$1" value="$2"
  case "$knob" in
    rps_cpus|xps_cpus) [[ "$value" =~ ^[0-9A-Fa-f,]+$ ]] ;;
    rps_flow_cnt) [[ "$value" =~ ^[0-9]+$ ]] ;;
    *) return 1 ;;
  esac
}

# Treat RPS, RFS, and XPS as independent capability classes. A class is safe to
# manage only when every currently exposed control in that class has a readable
# and valid pre-change value. This prevents one broken virtio XPS attribute from
# blocking useful RPS/RFS tuning while still preserving rollback for everything
# SSO actually writes.
cpu_irq_collect_capability_inventory() {
  local nic="$1" queue_prefix="$2" knob="$3" label="$4" out="$5"
  local net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local f value rel bad_path="" found=0
  local -a entries=()

  for f in "$net_root/$nic"/queues/"$queue_prefix"-*/"$knob"; do
    [[ -e "$f" || -L "$f" ]] || continue
    found=1
    if [[ ! -f "$f" || -L "$f" ]] || ! value="$(cat "$f" 2>/dev/null)" \
      || ! cpu_irq_queue_value_is_valid "$knob" "$value"; then
      bad_path="$f"
      break
    fi
    rel="${f#"$net_root/$nic/queues/"}"
    entries+=("$rel")
  done

  if [[ "$found" -eq 0 ]]; then
    info "$label: skipped (not exposed by NIC/driver)."
    return 2
  fi
  if [[ -n "$bad_path" ]]; then
    warn "$label: skipped (pre-change state is not safely readable: $bad_path)."
    return 2
  fi

  printf '%s\n' "${entries[@]}" >> "$out" || return 1
}

cpu_irq_build_managed_inventory() {
  local nic="$1" out="$2"
  local net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local supported=0 rc=0

  [[ -d "$net_root/$nic/queues" ]] || {
    err "CPU queue state is unavailable for NIC $nic: $net_root/$nic/queues"
    return 1
  }
  : > "$out" || return 1

  cpu_irq_collect_capability_inventory "$nic" rx rps_cpus RPS "$out" || rc=$?
  [[ "$rc" -eq 0 ]] && supported=$((supported + 1))
  [[ "$rc" -eq 1 ]] && return 1
  rc=0
  cpu_irq_collect_capability_inventory "$nic" rx rps_flow_cnt RFS "$out" || rc=$?
  [[ "$rc" -eq 0 ]] && supported=$((supported + 1))
  [[ "$rc" -eq 1 ]] && return 1
  rc=0
  cpu_irq_collect_capability_inventory "$nic" tx xps_cpus XPS "$out" || rc=$?
  [[ "$rc" -eq 0 ]] && supported=$((supported + 1))
  [[ "$rc" -eq 1 ]] && return 1

  if [[ "$supported" -eq 0 ]]; then
    warn "No RPS/RFS/XPS queue controls can be managed safely on NIC $nic."
    return 1
  fi
  LC_ALL=C sort -u "$out" -o "$out" || return 1
  [[ -s "$out" ]]
}

cpu_irq_inventory_has() {
  local inventory="$1" knob="$2"
  grep -Eq "/${knob}$" "$inventory" 2>/dev/null
}

# rollback.sh is loaded before cpu_irq.sh. These two definitions intentionally
# override its legacy all-or-nothing CPU runtime helpers. New snapshots contain
# managed-queues; old format-2 snapshots without that marker keep the original
# strict-topology restore behavior.
backup_capture_cpu_runtime() {
  local d="$1" inventory="${CPU_IRQ_MANAGED_INVENTORY_FILE:-}"
  local net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local runtime_dir="$d/cpu_irq/runtime"
  local nic value rel queue knob target

  [[ -n "$inventory" && -f "$inventory" && ! -L "$inventory" ]] || return 1
  nic="$(detect_nic)" || return 1
  [[ "$nic" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
  [[ -d "$net_root/$nic/queues" ]] || return 1
  command -v sysctl >/dev/null 2>&1 || return 1

  mkdir -p "$runtime_dir/queues" || return 1
  printf '%s\n' "$nic" > "$runtime_dir/nic" || return 1
  value="$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null)" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value" > "$runtime_dir/rps_sock_flow_entries" || return 1
  : > "$runtime_dir/managed-queues" || return 1

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    queue="${rel%%/*}"
    knob="${rel#*/}"
    [[ "$queue" != "$rel" && "$knob" != */* ]] || return 1
    case "$queue:$knob" in
      rx-[0-9]*:rps_cpus|rx-[0-9]*:rps_flow_cnt|tx-[0-9]*:xps_cpus) ;;
      *) return 1 ;;
    esac
    target="$net_root/$nic/queues/$rel"
    [[ -f "$target" && ! -L "$target" ]] || return 1
    value="$(cat "$target" 2>/dev/null)" || return 1
    cpu_irq_queue_value_is_valid "$knob" "$value" || return 1
    mkdir -p "$runtime_dir/queues/$queue" || return 1
    printf '%s\n' "$value" > "$runtime_dir/queues/$queue/$knob" || return 1
    printf '%s\n' "$rel" >> "$runtime_dir/managed-queues" || return 1
  done < "$inventory"

  LC_ALL=C sort -u "$runtime_dir/managed-queues" -o "$runtime_dir/managed-queues" || return 1
  [[ -s "$runtime_dir/managed-queues" ]] || return 1
  : > "$runtime_dir/COMPLETE" || return 1
}

backup_restore_cpu_runtime() {
  local d="$1" net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local runtime_dir="$d/cpu_irq/runtime"
  local nic expected_global captured rel queue knob target value actual path
  local failed=0 captured_count=0 current_count=0 declared_count=0 strict_topology=1
  local -A captured_inventory=() declared_inventory=()

  [[ -f "$runtime_dir/COMPLETE" && ! -L "$runtime_dir/COMPLETE" ]] || return 2
  [[ -d "$d" && ! -L "$d" ]] || return 1
  [[ -f "$d/FORMAT" && ! -L "$d/FORMAT" ]] || return 1
  [[ "$(cat "$d/FORMAT" 2>/dev/null || true)" == "$SSO_BACKUP_FORMAT" ]] || return 1
  [[ -f "$d/COMPLETE" && ! -L "$d/COMPLETE" ]] || return 1
  [[ -f "$runtime_dir/nic" && ! -L "$runtime_dir/nic" ]] || return 1
  [[ -f "$runtime_dir/rps_sock_flow_entries" && ! -L "$runtime_dir/rps_sock_flow_entries" ]] || return 1
  [[ -d "$runtime_dir/queues" && ! -L "$runtime_dir/queues" ]] || return 1

  nic="$(cat "$runtime_dir/nic" 2>/dev/null)" || return 1
  [[ "$nic" =~ ^[[:alnum:]_.:-]+$ && -d "$net_root/$nic/queues" ]] || return 1
  command -v sysctl >/dev/null 2>&1 || return 1
  expected_global="$(cat "$runtime_dir/rps_sock_flow_entries" 2>/dev/null)" || return 1
  [[ "$expected_global" =~ ^[0-9]+$ ]] || return 1

  while IFS= read -r captured; do
    [[ -n "$captured" && -f "$captured" && ! -L "$captured" ]] || continue
    rel="${captured#"$runtime_dir/queues/"}"
    queue="${rel%%/*}"; knob="${rel#*/}"
    case "$queue:$knob" in
      rx-[0-9]*:rps_cpus|rx-[0-9]*:rps_flow_cnt|tx-[0-9]*:xps_cpus) ;;
      *) return 1 ;;
    esac
    [[ -z "${captured_inventory[$rel]+x}" ]] || return 1
    value="$(cat "$captured" 2>/dev/null)" || return 1
    cpu_irq_queue_value_is_valid "$knob" "$value" || return 1
    captured_inventory["$rel"]=1
    captured_count=$((captured_count + 1))
  done < <(find "$runtime_dir/queues" -mindepth 2 -maxdepth 2 -type f -print 2>/dev/null | LC_ALL=C sort)
  [[ "$captured_count" -gt 0 ]] || return 1

  if [[ -e "$runtime_dir/managed-queues" || -L "$runtime_dir/managed-queues" ]]; then
    [[ -f "$runtime_dir/managed-queues" && ! -L "$runtime_dir/managed-queues" ]] || return 1
    strict_topology=0
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      [[ -n "${captured_inventory[$rel]+x}" && -z "${declared_inventory[$rel]+x}" ]] || return 1
      declared_inventory["$rel"]=1
      declared_count=$((declared_count + 1))
    done < "$runtime_dir/managed-queues"
    [[ "$declared_count" -eq "$captured_count" ]] || return 1
  fi

  for rel in "${!captured_inventory[@]}"; do
    target="$net_root/$nic/queues/$rel"
    [[ -f "$target" && ! -L "$target" ]] || return 1
  done

  if [[ "$strict_topology" -eq 1 ]]; then
    for path in "$net_root/$nic"/queues/rx-*/rps_cpus "$net_root/$nic"/queues/rx-*/rps_flow_cnt "$net_root/$nic"/queues/tx-*/xps_cpus; do
      [[ -e "$path" || -L "$path" ]] || continue
      [[ -f "$path" && ! -L "$path" ]] || return 1
      rel="${path#"$net_root/$nic/queues/"}"
      [[ -n "${captured_inventory[$rel]+x}" ]] || return 1
      current_count=$((current_count + 1))
    done
    [[ "$current_count" -eq "$captured_count" ]] || return 1
  fi

  if ! sysctl -w "net.core.rps_sock_flow_entries=$expected_global" >/dev/null 2>&1; then
    warn "Could not restore net.core.rps_sock_flow_entries=$expected_global."
    failed=1
  fi

  for rel in "${!captured_inventory[@]}"; do
    target="$net_root/$nic/queues/$rel"
    value="$(cat "$runtime_dir/queues/$rel" 2>/dev/null)" || return 1
    if ! printf '%s\n' "$value" > "$target" 2>/dev/null; then
      warn "Could not restore CPU queue value: $target"
      failed=1
      continue
    fi
    actual="$(cat "$target" 2>/dev/null || true)"
    [[ "$actual" == "$value" ]] || failed=1
  done

  actual="$(sysctl -n net.core.rps_sock_flow_entries 2>/dev/null || true)"
  [[ "$actual" == "$expected_global" ]] || failed=1
  for rel in "${!captured_inventory[@]}"; do
    value="$(cat "$runtime_dir/queues/$rel" 2>/dev/null)" || return 1
    actual="$(cat "$net_root/$nic/queues/$rel" 2>/dev/null || true)"
    [[ "$actual" == "$value" ]] || failed=1
  done
  return "$failed"
}

cpu_irq_write_restore_helper() {
  local nic="$1" inventory="$2"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  local helper="$local_sbin_dir/sso-cpuirq-restore" tmp rel

  [[ "$nic" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
  mkdir -p "$local_sbin_dir" || return 1
  tmp="$(mktemp "$local_sbin_dir/.sso-cpuirq-restore.XXXXXX")" || return 1
  if ! {
    cat <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/utils.sh"
# shellcheck source=/dev/null
source "$INSTALL_DIR/modules/cpu_irq.sh"
EOS
    printf 'nic=%q\n' "$nic"
    cat <<'EOS'
cpus="$(nproc)"
mask="$(hex_mask_all_cpus "$cpus")"
managed_queue_paths=(
EOS
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      printf '  %q\n' "$rel"
    done < "$inventory"
    cat <<'EOS'
)
queue_failed=false
global_failed=false
rps_any=false
rps_failed=false
rfs_any=false
rfs_failed=false
xps_any=false
xps_failed=false

for rel in "${managed_queue_paths[@]}"; do
  [[ "$rel" == rx-*/rps_flow_cnt ]] && rfs_any=true
done
if [[ "$rfs_any" == true ]]; then
  run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES" || {
    warn "Could not set rps_sock_flow_entries."
    global_failed=true
  }
fi
rfs_any=false

for rel in "${managed_queue_paths[@]}"; do
  target="/sys/class/net/$nic/queues/$rel"
  case "$rel" in
    rx-*/rps_cpus) rps_any=true; value="$mask" ;;
    rx-*/rps_flow_cnt) rfs_any=true; value="$RPS_FLOW_CNT" ;;
    tx-*/xps_cpus) xps_any=true; value="$mask" ;;
    *) warn "Ignoring invalid managed CPU queue path: $rel"; queue_failed=true; continue ;;
  esac
  if [[ ! -f "$target" || -L "$target" ]] || ! printf '%s\n' "$value" > "$target" 2>/dev/null; then
    queue_failed=true
    case "$rel" in
      rx-*/rps_cpus) rps_failed=true ;;
      rx-*/rps_flow_cnt) rfs_failed=true ;;
      tx-*/xps_cpus) xps_failed=true ;;
    esac
  fi
done

[[ "$rps_any" == true ]] || info "RPS: skipped (not managed for this NIC)."
[[ "$rfs_any" == true ]] || info "RFS: skipped (not managed for this NIC)."
[[ "$xps_any" == true ]] || info "XPS: skipped (not managed for this NIC)."
[[ "$rps_failed" == false ]] || warn "RPS: one or more managed queue writes were rejected."
[[ "$rfs_failed" == false ]] || warn "RFS: one or more managed queue writes were rejected."
[[ "$xps_failed" == false ]] || warn "XPS: one or more managed queue writes were rejected by the kernel/driver."
if [[ "$queue_failed" == true || "$global_failed" == true ]]; then
  warn "CPU queue restore was only partially applied."
  exit 1
fi
EOS
  } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod 755 "$tmp" || ! mv -f -- "$tmp" "$helper"; then
    rm -f -- "$tmp"
    return 1
  fi
}

cpu_irq_apply_managed_inventory() {
  local nic="$1" inventory="$2" mask="$3"
  local net_root="${SSO_SYS_CLASS_NET_DIR:-/sys/class/net}"
  local rel target value queue_failed=false
  local rps_any=false rps_failed=false rfs_any=false rfs_failed=false xps_any=false xps_failed=false

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    target="$net_root/$nic/queues/$rel"
    case "$rel" in
      rx-*/rps_cpus) rps_any=true; value="$mask" ;;
      rx-*/rps_flow_cnt) rfs_any=true; value="$RPS_FLOW_CNT" ;;
      tx-*/xps_cpus) xps_any=true; value="$mask" ;;
      *) queue_failed=true; warn "Ignoring invalid managed CPU queue path: $rel"; continue ;;
    esac
    if [[ ! -f "$target" || -L "$target" ]] || ! printf '%s\n' "$value" > "$target" 2>/dev/null; then
      queue_failed=true
      case "$rel" in
        rx-*/rps_cpus) rps_failed=true ;;
        rx-*/rps_flow_cnt) rfs_failed=true ;;
        tx-*/xps_cpus) xps_failed=true ;;
      esac
    fi
  done < "$inventory"

  [[ "$rps_any" == true ]] && { [[ "$rps_failed" == false ]] && ok "RPS: applied successfully." || warn "RPS: one or more managed queue writes were rejected."; } || info "RPS: skipped (unsupported/unreadable on this NIC)."
  [[ "$rfs_any" == true ]] && { [[ "$rfs_failed" == false ]] && ok "RFS: applied successfully." || warn "RFS: one or more managed queue writes were rejected."; } || info "RFS: skipped (unsupported/unreadable on this NIC)."
  [[ "$xps_any" == true ]] && { [[ "$xps_failed" == false ]] && ok "XPS: applied successfully." || warn "XPS: one or more managed queue writes were rejected by the kernel/driver."; } || info "XPS: skipped (unsupported/unreadable on this NIC)."
  [[ "$queue_failed" == false ]]
}

module_cpu_irq_apply_rps() {
  header
  section "Apply RPS/RFS/XPS"

  local nic cpus mask d inventory unit_tmp=""
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local runtime_failed=0 persistence_failed=0 persistence_ready=1 manage_rfs=0

  nic="$(detect_nic)"
  inventory="$(mktemp)" || { err "Could not allocate temporary CPU capability inventory."; pause; return 0; }
  if ! cpu_irq_build_managed_inventory "$nic" "$inventory"; then
    rm -f -- "$inventory"
    pause
    return 0
  fi

  CPU_IRQ_MANAGED_INVENTORY_FILE="$inventory"
  if ! d="$(backup_create "cpu_irq:rps_rfs_xps")"; then
    unset CPU_IRQ_MANAGED_INVENTORY_FILE
    rm -f -- "$inventory"
    err "Could not create a complete pre-change backup for the supported CPU queue controls."
    warn "No RPS/RFS/XPS settings were changed."
    pause
    return 0
  fi
  unset CPU_IRQ_MANAGED_INVENTORY_FILE

  cpus="$(nproc)"
  if ! mask="$(hex_mask_all_cpus "$cpus")"; then
    rm -f -- "$inventory"
    err "Could not calculate a CPU mask for $cpus CPUs."
    pause
    return 0
  fi
  info "NIC: $nic | CPUs: $cpus | Mask: $mask"

  cpu_irq_inventory_has "$inventory" rps_flow_cnt && manage_rfs=1
  if [[ "$manage_rfs" -eq 1 ]]; then
    if ! mkdir -p "$sysctl_dir" || ! printf '# SSO: RPS/RFS global settings\nnet.core.rps_sock_flow_entries=%s\n' "$RPS_SOCK_FLOW_ENTRIES" > "$sysctl_dir/99-sso-rps.conf"; then
      persistence_failed=1
      warn "Could not persist rps_sock_flow_entries."
    fi
    if ! run_step "Applying sysctl settings" sysctl --system; then
      runtime_failed=1
      warn "sysctl reported errors; some global runtime settings may not have been applied."
    fi
  else
    rm -f -- "$sysctl_dir/99-sso-rps.conf" 2>/dev/null || { persistence_failed=1; warn "Could not remove stale SSO RFS persistence."; }
  fi

  if ! cpu_irq_write_restore_helper "$nic" "$inventory"; then
    persistence_failed=1; persistence_ready=0
    warn "Could not write the CPU/IRQ restore helper."
  fi

  if ! mkdir -p "$systemd_dir"; then
    persistence_failed=1; persistence_ready=0
    warn "Could not prepare the systemd unit directory."
  elif [[ "$persistence_ready" -eq 1 ]]; then
    unit_tmp="$(mktemp "$systemd_dir/.sso-cpuirq.service.XXXXXX")" || { persistence_failed=1; persistence_ready=0; }
    if [[ "$persistence_ready" -eq 1 ]]; then
      if ! cat > "$unit_tmp" <<'EOF_UNIT'
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
      then
        persistence_failed=1; persistence_ready=0
      elif ! mv -f -- "$unit_tmp" "$systemd_dir/sso-cpuirq.service"; then
        persistence_failed=1; persistence_ready=0
      fi
      if [[ "$persistence_ready" -eq 0 ]]; then
        rm -f -- "$unit_tmp" 2>/dev/null || true
        warn "Could not write sso-cpuirq.service."
      fi
    fi
  fi

  if [[ "$persistence_ready" -eq 1 ]] && ! run_step "Reloading systemd units" systemctl daemon-reload; then
    persistence_failed=1; persistence_ready=0
    warn "systemd daemon-reload failed."
  fi
  if [[ "$persistence_ready" -eq 1 ]] && ! run_step "Enabling SSO CPU/IRQ service" systemctl enable --now sso-cpuirq.service; then
    persistence_failed=1; persistence_ready=0
    warn "Could not enable sso-cpuirq.service; reboot persistence is not confirmed."
  fi
  if [[ "$persistence_ready" -eq 0 ]]; then
    systemctl disable sso-cpuirq.service >/dev/null 2>&1 || true
  fi

  if [[ "$manage_rfs" -eq 1 ]] && ! run_step "Setting rps_sock_flow_entries" sysctl -w "net.core.rps_sock_flow_entries=$RPS_SOCK_FLOW_ENTRIES"; then
    runtime_failed=1
    warn "Could not set rps_sock_flow_entries."
  fi

  info "Applying supported per-queue CPU settings..."
  cpu_irq_apply_managed_inventory "$nic" "$inventory" "$mask" || runtime_failed=1
  rm -f -- "$inventory"

  if [[ "$runtime_failed" -ne 0 || "$persistence_failed" -ne 0 ]]; then
    warn "CPU queue tuning finished with warnings; runtime and/or reboot persistence is only partially confirmed. (Backup: $d)"
  else
    ok "Applied supported RPS/RFS/XPS settings with reboot persistence. (Backup: $d)"
  fi
  module_cpu_irq_show
}

module_cpu_irq_show() {
  header
  section "IRQ/RPS status"
  local nic f
  nic="$(detect_nic)"
  info "NIC: $nic"
  systemctl is-active irqbalance 2>/dev/null | sed 's/^/irqbalance: /' || true
  echo ""
  info "RPS/RFS:"
  grep -H . /sys/class/net/"$nic"/queues/rx-*/rps_cpus 2>/dev/null || true
  grep -H . /sys/class/net/"$nic"/queues/rx-*/rps_flow_cnt 2>/dev/null || true
  echo ""
  info "XPS:"
  if compgen -G "/sys/class/net/$nic/queues/tx-*/xps_cpus" >/dev/null; then
    if ! grep -H . /sys/class/net/"$nic"/queues/tx-*/xps_cpus 2>/dev/null; then
      for f in /sys/class/net/"$nic"/queues/tx-*/xps_cpus; do
        [[ -e "$f" || -L "$f" ]] || continue
        if ! cat "$f" >/dev/null 2>&1; then
          warn "Present but not readable ($f). SSO skips unsupported XPS while still allowing safe RPS/RFS tuning."
        fi
      done
    fi
  else
    info "XPS: no TX queues/xps_cpus found."
  fi
  pause
}
