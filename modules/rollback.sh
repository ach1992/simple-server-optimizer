#!/usr/bin/env bash
set -Eeuo pipefail

# This module uses globals from sso.sh:
# STATE_DIR, BACKUP_DIR_BASE

SSO_BACKUP_FORMAT="2"

backup_path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

backup_capture_file_state() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  rm -f -- "${dst}.absent" 2>/dev/null || true

  if backup_path_exists "$src"; then
    rm -f -- "$dst" 2>/dev/null || true
    cp -a -- "$src" "$dst"
  else
    rm -f -- "$dst" 2>/dev/null || true
    : > "${dst}.absent"
  fi
}

backup_restore_file_state() {
  local captured="$1"
  local target="$2"

  if backup_path_exists "$captured"; then
    mkdir -p "$(dirname "$target")"
    rm -f -- "$target" 2>/dev/null || true
    cp -a -- "$captured" "$target"
    return 0
  fi

  if [[ -f "${captured}.absent" ]]; then
    rm -f -- "$target" 2>/dev/null || true
    return 0
  fi

  return 2
}

backup_create_dir() {
  mkdir -p "$BACKUP_DIR_BASE"

  local prefix d i
  prefix="$BACKUP_DIR_BASE/$(ts)"
  d="$prefix"
  if mkdir "$d" 2>/dev/null; then
    printf '%s\n' "$d"
    return 0
  fi

  for ((i=1; i<=9999; i++)); do
    printf -v d '%s-%04d' "$prefix" "$i"
    if mkdir "$d" 2>/dev/null; then
      printf '%s\n' "$d"
      return 0
    fi
  done

  printf 'Unable to allocate a unique backup directory under %s\n' "$BACKUP_DIR_BASE" >&2
  return 1
}

backup_capture_sysctl() {
  local d="$1"
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"
  local name

  mkdir -p "$d/sysctl"
  for name in \
    99-sso-qdisc.conf \
    99-sso-bbr.conf \
    99-sso-net-tuning.conf \
    99-sso-rps.conf; do
    backup_capture_file_state "$sysctl_dir/$name" "$d/sysctl/$name"
  done

  # This legacy path is not SSO-namespaced, so its prior presence/absence must
  # be explicit before SSO writes it.
  backup_capture_file_state "$modules_load_dir/bbr.conf" "$d/sysctl/bbr.conf"
}

backup_capture_qdisc() {
  local d="$1"
  mkdir -p "$d/net"
  local nic
  nic="$(detect_nic)"
  printf '%s\n' "$nic" > "$d/net/nic"
  tc qdisc show dev "$nic" > "$d/net/tc-qdisc.txt" 2>/dev/null || true

  # Capture the runtime values SSO directly changes for fq/BBR. Replaying an
  # arbitrary `tc qdisc show` line is not reliable across kernels/drivers, so
  # rollback restores these supported sysctl controls instead.
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n net.core.default_qdisc > "$d/net/net.core.default_qdisc" 2>/dev/null || true
    sysctl -n net.ipv4.tcp_congestion_control > "$d/net/net.ipv4.tcp_congestion_control" 2>/dev/null || true
  fi
}

backup_restore_network_runtime() {
  local d="$1"
  command -v sysctl >/dev/null 2>&1 || return 2

  local key f value failed=0
  for key in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
    f="$d/net/$key"
    [[ -s "$f" ]] || continue
    value="$(cat "$f")"
    if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
      warn "Could not restore runtime sysctl $key=$value."
      failed=1
    fi
  done

  return "$failed"
}

backup_capture_firewall() {
  local d="$1"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  mkdir -p "$d/firewall"

  backup_capture_file_state \
    "$systemd_dir/sso-firewall.service" \
    "$d/firewall/sso-firewall.service"
  backup_capture_file_state \
    "$local_sbin_dir/sso-firewall-restore" \
    "$d/firewall/sso-firewall-restore"

  local runtime="unknown"
  local inspected=0
  if command -v nft >/dev/null 2>&1; then
    inspected=1
    if nft list table inet sso >/dev/null 2>&1 || nft list table ip sso >/dev/null 2>&1; then
      runtime="nft"
    fi
  fi
  if [[ "$runtime" == "unknown" ]] && command -v iptables >/dev/null 2>&1; then
    inspected=1
    if iptables -S SSO_IN >/dev/null 2>&1 || iptables -S SSO_OUT >/dev/null 2>&1; then
      runtime="ipset"
    fi
  fi
  if [[ "$runtime" == "unknown" && "$inspected" == "1" ]]; then
    runtime="none"
  fi
  printf '%s\n' "$runtime" > "$d/firewall/runtime.state"
}

backup_capture_cpu_irq() {
  local d="$1"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  mkdir -p "$d/cpu_irq"

  backup_capture_file_state \
    "$systemd_dir/sso-cpuirq.service" \
    "$d/cpu_irq/sso-cpuirq.service"
  backup_capture_file_state \
    "$local_sbin_dir/sso-cpuirq-restore" \
    "$d/cpu_irq/sso-cpuirq-restore"
}

backup_capture_state() {
  local d="$1"
  mkdir -p "$d/state"

  backup_capture_file_state "$STATE_DIR/blocklist-ip.ipv4" "$d/state/blocklist-ip.ipv4"
  backup_capture_file_state "$STATE_DIR/whitelist-ip.ipv4" "$d/state/whitelist-ip.ipv4"
  backup_capture_file_state "$STATE_DIR/bittorrent-block.enabled" "$d/state/bittorrent-block.enabled"
  backup_capture_file_state "$STATE_DIR/install_dir" "$d/state/install_dir"
}

backup_capture_fail2ban() {
  local d="$1"
  local managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  local nginx_marker="${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}"
  mkdir -p "$d/fail2ban"

  if [[ -f "$managed" ]]; then
    cp -a "$managed" "$d/fail2ban/sso.local"
  else
    : > "$d/fail2ban/sso.local.absent"
  fi

  if [[ -f "$nginx_marker" ]]; then
    cp -a "$nginx_marker" "$d/fail2ban/nginx.enabled"
  else
    : > "$d/fail2ban/nginx.enabled.absent"
  fi
}

backup_capture_service_state() {
  local d="$1"
  local unit="$2"
  local sd="$d/services/$unit"
  mkdir -p "$sd"

  local load="unknown" enabled="unknown" active="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ -n "$load" ]] || load="unknown"
    [[ -n "$enabled" ]] || enabled="unknown"
    [[ -n "$active" ]] || active="unknown"
  fi

  printf '%s\n' "$load" > "$sd/load"
  printf '%s\n' "$enabled" > "$sd/enabled"
  printf '%s\n' "$active" > "$sd/active"
}

backup_capture_services() {
  local d="$1"
  local unit
  for unit in \
    sso-firewall.service \
    sso-cpuirq.service \
    irqbalance.service \
    fail2ban.service; do
    backup_capture_service_state "$d" "$unit"
  done
}

backup_mark() {
  local d="$1"
  local tag="$2"
  printf '%s\n' "$tag" > "$d/TAG"
  printf '%s\n' "$SSO_BACKUP_FORMAT" > "$d/FORMAT"
}

backup_create() {
  local tag="$1"
  local d
  d="$(backup_create_dir)"
  backup_capture_sysctl "$d"
  backup_capture_qdisc "$d"
  backup_capture_firewall "$d"
  backup_capture_cpu_irq "$d"
  backup_capture_state "$d"
  backup_capture_fail2ban "$d"
  backup_capture_services "$d"
  backup_mark "$d" "$tag"
  printf '%s\n' "$d"
}

module_rollback_list() {
  header
  section "Backups"
  if [[ ! -d "$BACKUP_DIR_BASE" ]]; then
    warn "No backups directory."
    pause; return
  fi
  find "$BACKUP_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
    | sort | tail -n 50 | sed 's/^/ - /' || true
  pause
}

backup_last_dir() {
  local name
  name="$(find "$BACKUP_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "$name" ]] && printf '%s/%s\n' "$BACKUP_DIR_BASE" "$name"
}

backup_first_current_format_dir() {
  local name d
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    d="$BACKUP_DIR_BASE/$name"
    if [[ -f "$d/FORMAT" ]] && [[ "$(cat "$d/FORMAT" 2>/dev/null || true)" == "$SSO_BACKUP_FORMAT" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done < <(find "$BACKUP_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  return 1
}

backup_service_state_value() {
  local d="$1"
  local unit="$2"
  local key="$3"
  local f="$d/services/$unit/$key"
  [[ -f "$f" ]] || return 2
  cat "$f"
}

backup_restore_service_state() {
  local d="$1"
  local unit="$2"
  local restart_active="${3:-0}"
  local sd="$d/services/$unit"
  [[ -d "$sd" ]] || return 2
  command -v systemctl >/dev/null 2>&1 || return 1

  local load enabled active
  load="$(cat "$sd/load" 2>/dev/null || echo unknown)"
  enabled="$(cat "$sd/enabled" 2>/dev/null || echo unknown)"
  active="$(cat "$sd/active" 2>/dev/null || echo unknown)"

  if [[ "$load" == "not-found" ]]; then
    if declare -F systemd_disable_now_safe >/dev/null 2>&1; then
      systemd_disable_now_safe "$unit"
    else
      systemctl stop "$unit" >/dev/null 2>&1 || true
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
    return 0
  fi

  if [[ "$enabled" == "masked" ]]; then
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl mask "$unit" >/dev/null 2>&1 || return 1
    return 0
  fi

  systemctl unmask "$unit" >/dev/null 2>&1 || true
  case "$enabled" in
    enabled) systemctl enable "$unit" >/dev/null 2>&1 || return 1 ;;
    disabled) systemctl disable "$unit" >/dev/null 2>&1 || return 1 ;;
  esac

  case "$active" in
    active)
      if [[ "$restart_active" == "1" ]]; then
        systemctl restart "$unit" >/dev/null 2>&1 || return 1
      else
        systemctl start "$unit" >/dev/null 2>&1 || return 1
      fi
      ;;
    inactive) systemctl stop "$unit" >/dev/null 2>&1 || return 1 ;;
  esac

  return 0
}

remove_sso_firewall_runtime() {
  local failed=0

  if command -v nft >/dev/null 2>&1; then
    local family
    for family in inet ip; do
      if nft list table "$family" sso >/dev/null 2>&1; then
        nft flush table "$family" sso >/dev/null 2>&1 || failed=1
        nft delete table "$family" sso >/dev/null 2>&1 || failed=1
      fi
      if nft list table "$family" sso >/dev/null 2>&1; then
        failed=1
      fi
    done
  fi

  if command -v iptables >/dev/null 2>&1; then
    local i
    for ((i=0; i<32; i++)); do
      iptables -C INPUT -j SSO_IN >/dev/null 2>&1 || break
      iptables -D INPUT -j SSO_IN >/dev/null 2>&1 || { failed=1; break; }
    done
    if iptables -C INPUT -j SSO_IN >/dev/null 2>&1; then failed=1; fi

    for ((i=0; i<32; i++)); do
      iptables -C OUTPUT -j SSO_OUT >/dev/null 2>&1 || break
      iptables -D OUTPUT -j SSO_OUT >/dev/null 2>&1 || { failed=1; break; }
    done
    if iptables -C OUTPUT -j SSO_OUT >/dev/null 2>&1; then failed=1; fi

    iptables -F SSO_IN >/dev/null 2>&1 || true
    iptables -F SSO_OUT >/dev/null 2>&1 || true
    iptables -X SSO_IN >/dev/null 2>&1 || true
    iptables -X SSO_OUT >/dev/null 2>&1 || true
    if iptables -S SSO_IN >/dev/null 2>&1 || iptables -S SSO_OUT >/dev/null 2>&1; then
      failed=1
    fi
  fi

  if command -v ipset >/dev/null 2>&1; then
    ipset destroy sso_block_v4 >/dev/null 2>&1 || true
    ipset destroy sso_white_v4 >/dev/null 2>&1 || true
    if ipset list sso_block_v4 >/dev/null 2>&1 || ipset list sso_white_v4 >/dev/null 2>&1; then
      failed=1
    fi
  fi

  return "$failed"
}

restore_from_dir() {
  local d="$1"
  [[ -d "$d" ]] || { err "Backup not found: $d"; return 1; }

  warn "Restoring SSO-owned configs from: $d"
  warn "This rollback is limited to files/services created or explicitly captured by SSO."

  local format=""
  format="$(cat "$d/FORMAT" 2>/dev/null || true)"
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  local name touched_systemd=0

  # Restore SSO-owned sysctl files. New-format backups explicitly encode
  # prior absence. Legacy backups may safely use absence-by-omission only for
  # SSO-namespaced sysctl paths.
  for name in 99-sso-qdisc.conf 99-sso-bbr.conf 99-sso-net-tuning.conf 99-sso-rps.conf; do
    if ! backup_restore_file_state "$d/sysctl/$name" "$sysctl_dir/$name"; then
      if [[ "$format" != "$SSO_BACKUP_FORMAT" ]]; then
        rm -f -- "$sysctl_dir/$name" 2>/dev/null || true
      fi
    fi
  done

  # bbr.conf is not namespaced. Delete it only when a current-format backup
  # explicitly says it was absent; otherwise preserve ambiguous legacy state.
  if ! backup_restore_file_state "$d/sysctl/bbr.conf" "$modules_load_dir/bbr.conf"; then
    if [[ -f "$d/sysctl/bbr.conf" ]]; then
      cp -a -- "$d/sysctl/bbr.conf" "$modules_load_dir/bbr.conf"
    fi
  fi

  # Restore SSO runtime state captured by current-format backups.
  backup_restore_file_state "$d/state/blocklist-ip.ipv4" "$STATE_DIR/blocklist-ip.ipv4" || true
  backup_restore_file_state "$d/state/whitelist-ip.ipv4" "$STATE_DIR/whitelist-ip.ipv4" || true
  backup_restore_file_state "$d/state/bittorrent-block.enabled" "$STATE_DIR/bittorrent-block.enabled" || true
  backup_restore_file_state "$d/state/install_dir" "$STATE_DIR/install_dir" || true

  run_step "Applying sysctl settings (rollback)" sysctl --system || warn "sysctl apply had errors (continuing)."

  local runtime_rc=0
  backup_restore_network_runtime "$d" || runtime_rc=$?
  if [[ "$runtime_rc" != "0" && "$runtime_rc" != "2" ]]; then
    err "Rollback could not fully restore the captured fq/BBR runtime state."
    return 1
  fi

  # CPU/IRQ persistence artifacts and service lifecycle.
  if backup_restore_file_state "$d/cpu_irq/sso-cpuirq.service" "$systemd_dir/sso-cpuirq.service"; then
    touched_systemd=1
  fi
  backup_restore_file_state "$d/cpu_irq/sso-cpuirq-restore" "$local_sbin_dir/sso-cpuirq-restore" || true

  # Firewall persistence artifacts.
  if backup_restore_file_state "$d/firewall/sso-firewall.service" "$systemd_dir/sso-firewall.service"; then
    touched_systemd=1
  elif [[ "$format" != "$SSO_BACKUP_FORMAT" ]]; then
    rm -f -- "$systemd_dir/sso-firewall.service" 2>/dev/null || true
    if [[ -f "$d/firewall/sso-firewall.service" ]]; then
      cp -a -- "$d/firewall/sso-firewall.service" "$systemd_dir/sso-firewall.service"
    fi
    touched_systemd=1
  fi

  if ! backup_restore_file_state "$d/firewall/sso-firewall-restore" "$local_sbin_dir/sso-firewall-restore"; then
    if [[ "$format" != "$SSO_BACKUP_FORMAT" ]]; then
      rm -f -- "$local_sbin_dir/sso-firewall-restore" 2>/dev/null || true
      if [[ -f "$d/firewall/sso-firewall-restore" ]]; then
        cp -a -- "$d/firewall/sso-firewall-restore" "$local_sbin_dir/sso-firewall-restore"
      fi
    fi
  fi

  if [[ "$touched_systemd" == "1" ]]; then
    run_step "Reloading systemd units (rollback)" systemctl daemon-reload || warn "systemd daemon-reload failed (continuing)."
  fi

  # Restore CPU/IRQ persistence service state without inventing enablement.
  local cpu_rc=0
  backup_restore_service_state "$d" sso-cpuirq.service 1 || cpu_rc=$?
  if [[ "$cpu_rc" != "0" ]]; then
    [[ "$cpu_rc" == "2" ]] || warn "Could not fully restore sso-cpuirq.service state."
  fi

  # Restore firewall runtime only where the prior state is credible.
  local fw_runtime=""
  fw_runtime="$(cat "$d/firewall/runtime.state" 2>/dev/null || true)"
  if [[ "$fw_runtime" == "none" ]]; then
    remove_sso_firewall_runtime || warn "Some SSO firewall runtime state could not be removed during rollback."
  fi

  local fw_rc=0
  backup_restore_service_state "$d" sso-firewall.service 1 || fw_rc=$?
  if [[ "$fw_rc" != "0" ]]; then
    if [[ "$fw_rc" == "2" ]]; then
      # Legacy backup: do not infer enablement from a unit file alone. If the
      # service is already active, restart it to consume restored files/state.
      if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sso-firewall.service 2>/dev/null; then
        systemctl restart sso-firewall.service >/dev/null 2>&1 || warn "Could not restart sso-firewall.service."
      fi
    else
      warn "Could not fully restore sso-firewall.service state."
    fi
  fi

  if [[ "$fw_runtime" == "nft" || "$fw_runtime" == "ipset" ]]; then
    local fw_active=""
    fw_active="$(backup_service_state_value "$d" sso-firewall.service active 2>/dev/null || true)"
    if [[ "$fw_active" != "active" ]]; then
      warn "Prior SSO firewall runtime existed without an active captured persistence service; exact runtime replay was skipped."
    fi
  fi

  # Restore only SSO-owned Fail2Ban state; never overwrite jail.local.
  local f2b_managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  local f2b_nginx_marker="${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}"
  local f2b_touched=0
  if [[ -f "$d/fail2ban/sso.local" ]]; then
    ensure_dirs "$(dirname "$f2b_managed")"
    cp -a "$d/fail2ban/sso.local" "$f2b_managed"
    f2b_touched=1
  elif [[ -f "$d/fail2ban/sso.local.absent" ]]; then
    rm -f "$f2b_managed"
    f2b_touched=1
  fi

  if [[ -f "$d/fail2ban/nginx.enabled" ]]; then
    ensure_dirs "$(dirname "$f2b_nginx_marker")"
    cp -a "$d/fail2ban/nginx.enabled" "$f2b_nginx_marker"
  elif [[ -f "$d/fail2ban/nginx.enabled.absent" ]]; then
    rm -f "$f2b_nginx_marker"
  fi

  if [[ "$f2b_touched" == "1" ]] && cmd_exists fail2ban-client; then
    if ! fail2ban-client -t; then
      err "Restored SSO Fail2Ban configuration did not validate; Fail2Ban service state was not changed."
      return 1
    fi
  fi

  local f2b_rc=0
  backup_restore_service_state "$d" fail2ban.service 1 || f2b_rc=$?
  if [[ "$f2b_rc" != "0" ]]; then
    if [[ "$f2b_rc" == "2" ]]; then
      if [[ "$f2b_touched" == "1" ]] && command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet fail2ban 2>/dev/null; then
        run_step "Restarting Fail2Ban (rollback)" systemctl restart fail2ban || warn "Could not restart Fail2Ban (continuing)."
      fi
    else
      warn "Could not fully restore fail2ban.service state."
    fi
  fi

  # irqbalance is operator-owned when SSO did not install the package. Restore
  # the captured service lifecycle but do not purge packages during rollback.
  local irq_rc=0
  backup_restore_service_state "$d" irqbalance.service 0 || irq_rc=$?
  if [[ "$irq_rc" != "0" ]]; then
    [[ "$irq_rc" == "2" ]] || warn "Could not fully restore irqbalance.service state."
  fi

  ok "Rollback completed."
  pause
}

module_rollback_last() {
  header
  section "Rollback last backup"
  local d
  d="$(backup_last_dir)"
  if [[ -z "${d:-}" ]] || [[ ! -d "$d" ]]; then
    err "No backups found."
    pause; return
  fi
  if ! restore_from_dir "$d"; then
    err "Rollback did not complete successfully."
    pause
    return 0
  fi
}

module_rollback_choose() {
  header
  section "Rollback choose backup"
  local list
  list="$(find "$BACKUP_DIR_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | tail -n 30 || true)"
  if [[ -z "${list:-}" ]]; then
    err "No backups found."
    pause; return
  fi
  echo "$list" | nl -w2 -s') '
  echo "0) Back"
  local idx=""
  prompt_choice "Select number" idx
  [[ "$idx" == "0" ]] && return
  local selected
  selected="$(echo "$list" | sed -n "${idx}p")"
  if [[ -z "${selected:-}" ]]; then
    err "Invalid selection."
    pause; return
  fi
  if ! restore_from_dir "$BACKUP_DIR_BASE/$selected"; then
    err "Rollback did not complete successfully."
    pause
    return 0
  fi
}
