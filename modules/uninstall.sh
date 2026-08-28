#!/usr/bin/env bash
set -Eeuo pipefail

# Uninstall SSO-owned state while restoring shared/operator state only where a
# resource-specific backup establishes a trustworthy pre-ownership baseline.

uninstall_restore_shared_file_baseline() {
  local baseline="$1"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"
  local rc=0 format=""

  if [[ -n "$baseline" ]]; then
    format="$(cat "$baseline/FORMAT" 2>/dev/null || true)"
    backup_restore_file_state "$baseline/sysctl/bbr.conf" "$modules_load_dir/bbr.conf" || rc=$?
    case "$rc" in
      0) return 0 ;;
      1) return 1 ;;
      2)
        # A v2 resource baseline must explicitly encode presence/absence. A
        # legacy baseline is trustworthy only when it positively captured the
        # operator file; omission cannot prove prior absence.
        if [[ "$format" == "$SSO_BACKUP_FORMAT" ]]; then
          return 1
        fi
        ;;
      *) return 1 ;;
    esac
  fi

  if [[ -e "$modules_load_dir/bbr.conf" || -L "$modules_load_dir/bbr.conf" ]]; then
    warn "No trustworthy pre-BBR baseline for /etc/modules-load.d/bbr.conf; preserving the current file rather than guessing ownership."
  fi
  return 0
}

uninstall_remove_owned_persistence_files() {
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  local failed=0 path

  rm -f "$sysctl_dir"/99-sso-*.conf 2>/dev/null || failed=1
  rm -f \
    "$systemd_dir/sso-firewall.service" \
    "$systemd_dir/sso-cpuirq.service" \
    "$local_sbin_dir/sso-firewall-restore" \
    "$local_sbin_dir/sso-cpuirq-restore" \
    2>/dev/null || failed=1

  if compgen -G "$sysctl_dir/99-sso-*.conf" >/dev/null; then
    failed=1
  fi
  for path in \
    "$systemd_dir/sso-firewall.service" \
    "$systemd_dir/sso-cpuirq.service" \
    "$local_sbin_dir/sso-firewall-restore" \
    "$local_sbin_dir/sso-cpuirq-restore"; do
    if [[ -e "$path" || -L "$path" ]]; then failed=1; fi
  done

  return "$failed"
}

uninstall_remove_launcher() {
  local local_bin_dir="${SSO_LOCAL_BIN_DIR:-/usr/local/bin}"
  rm -f "$local_bin_dir/sso" 2>/dev/null || return 1
  [[ ! -e "$local_bin_dir/sso" && ! -L "$local_bin_dir/sso" ]]
}

uninstall_disable_sso_service() {
  local unit="$1"
  systemd_disable_now_safe "$unit"
  command -v systemctl >/dev/null 2>&1 || return 1

  local load active enabled
  load="$(systemd_load_state "$unit")"
  [[ -n "$load" ]] || return 1
  [[ "$load" == "not-found" ]] && return 0

  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"

  case "$active" in
    inactive|failed|unknown) ;;
    *) return 1 ;;
  esac
  case "$enabled" in
    disabled|masked|masked-runtime|static|indirect|generated|transient|not-found) ;;
    *) return 1 ;;
  esac
  return 0
}

uninstall_safe_recursive_target() {
  local path="$1"
  [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || return 1
  case "$path" in
    /etc|/usr|/usr/local|/root|/var|/home|/tmp) return 1 ;;
  esac
  return 0
}

# install.sh creates ${SSO_DIR}.bak only after verifying the previous install
# contains the complete required SSO payload. Re-check the same ownership
# signature before uninstall is allowed to delete that recursive fallback.
uninstall_sso_payload_dir_is_recognized() {
  local root="$1" rel

  [[ -d "$root" && ! -L "$root" ]] || return 1
  for rel in \
    install.sh \
    sso.sh \
    modules/utils.sh \
    modules/network.sh \
    modules/cpu_irq.sh \
    modules/firewall.sh \
    modules/fail2ban.sh \
    modules/rollback.sh \
    modules/uninstall.sh \
    assets/whitelist-default.ipv4; do
    [[ -f "$root/$rel" && ! -L "$root/$rel" ]] || return 1
  done
  return 0
}

uninstall_remove_fail2ban_owned_state() {
  local managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  local marker="${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}"

  rm -f -- "$managed" "$marker" 2>/dev/null || return 1
  backup_path_exists "$managed" && return 1
  backup_path_exists "$marker" && return 1
  return 0
}

uninstall_restore_fail2ban_service() {
  local baseline="$1"
  [[ -n "$baseline" ]] || return 2

  local desired_active=""
  desired_active="$(backup_service_state_value "$baseline" fail2ban.service active 2>/dev/null || true)"
  if [[ "$desired_active" == "active" ]]; then
    if ! cmd_exists fail2ban-client; then
      warn "Fail2Ban validation tooling is unavailable; prior active service state was not restarted."
      return 1
    fi
    if ! fail2ban-client -t; then
      warn "Fail2Ban config is invalid after removing SSO state; prior active service state was not restarted."
      return 1
    fi
  fi

  backup_restore_service_state "$baseline" fail2ban.service 1
}

# Package ownership permits SSO to stop Fail2Ban, but only that marker-owned
# path may do so. Treat lifecycle evidence as a tuple: loaded/masked units must
# be positively inactive, while a not-found unit is accepted only with an
# explicitly consistent absent-unit active state. Anything else fails closed.
uninstall_fail2ban_lifecycle_is_safe() {
  command -v systemctl >/dev/null 2>&1 || return 1

  local load="" active=""
  load="$(systemd_load_state fail2ban.service)"
  active="$(systemctl is-active fail2ban.service 2>/dev/null || true)"

  case "$load" in
    loaded|masked)
      [[ "$active" == "inactive" ]]
      ;;
    not-found)
      case "$active" in
        inactive|unknown|not-found) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

uninstall_stop_owned_fail2ban_before_purge() {
  command -v systemctl >/dev/null 2>&1 || return 1

  local load="" active=""
  load="$(systemd_load_state fail2ban.service)"
  active="$(systemctl is-active fail2ban.service 2>/dev/null || true)"

  case "$load" in
    loaded|masked)
      case "$active" in
        inactive)
          ;;
        active|activating|reloading|deactivating)
          if ! run_step "Stopping SSO-installed Fail2Ban" systemctl stop fail2ban.service; then
            return 1
          fi
          ;;
        *)
          return 1
          ;;
      esac
      ;;
    not-found)
      case "$active" in
        inactive|unknown|not-found) ;;
        *) return 1 ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac

  # Re-read the tuple immediately before purge. A nominally successful stop or
  # a transient first observation is not sufficient authorization to purge.
  uninstall_fail2ban_lifecycle_is_safe
}

# Detect a real SSO RPS/RFS/XPS apply, not merely an empty namespaced test or
# stale placeholder. install/apply writes at least one of these recognizable
# payloads before changing live queue state.
uninstall_cpu_runtime_owned() {
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  local rps_file="$sysctl_dir/99-sso-rps.conf"
  local unit_file="$systemd_dir/sso-cpuirq.service"
  local restore_file="$local_sbin_dir/sso-cpuirq-restore"

  if [[ -f "$rps_file" && ! -L "$rps_file" ]] \
    && grep -Eq '^[[:space:]]*net\.core\.rps_sock_flow_entries=' "$rps_file"; then
    return 0
  fi
  if [[ -f "$unit_file" && ! -L "$unit_file" ]] \
    && grep -Fq 'Description=SSO CPU/IRQ tuning (RPS/RFS/XPS)' "$unit_file"; then
    return 0
  fi
  if [[ -f "$restore_file" && ! -L "$restore_file" ]] \
    && grep -Fq 'net.core.rps_sock_flow_entries=' "$restore_file"; then
    return 0
  fi
  return 1
}

# A usable RPS snapshot is a pre-ownership baseline only when it is a fully
# certified current-format snapshot and positively proves the SSO RPS sysctl
# file, CPU unit, and restore helper were all absent before runtime mutation.
uninstall_cpu_runtime_snapshot_is_preownership() {
  local d="$1"
  local tag="" format="" load="" enabled="" active=""
  local service_state_dir="$d/services/sso-cpuirq.service"

  [[ -d "$d" && ! -L "$d" ]] || return 1
  [[ ! -e "$d/INCOMPLETE" && ! -L "$d/INCOMPLETE" ]] || return 1
  [[ -f "$d/TAG" && ! -L "$d/TAG" ]] || return 1
  [[ -f "$d/FORMAT" && ! -L "$d/FORMAT" ]] || return 1
  [[ -f "$d/COMPLETE" && ! -L "$d/COMPLETE" ]] || return 1
  tag="$(cat "$d/TAG" 2>/dev/null)" || return 1
  format="$(cat "$d/FORMAT" 2>/dev/null)" || return 1
  [[ "$tag" == "cpu_irq:rps_rfs_xps" && "$format" == "$SSO_BACKUP_FORMAT" ]] || return 1

  [[ -d "$d/cpu_irq" && ! -L "$d/cpu_irq" ]] || return 1
  [[ -d "$d/cpu_irq/runtime" && ! -L "$d/cpu_irq/runtime" ]] || return 1
  [[ -d "$d/cpu_irq/runtime/queues" && ! -L "$d/cpu_irq/runtime/queues" ]] || return 1
  [[ -f "$d/cpu_irq/runtime/COMPLETE" && ! -L "$d/cpu_irq/runtime/COMPLETE" ]] || return 1
  [[ -f "$d/cpu_irq/runtime/nic" && ! -L "$d/cpu_irq/runtime/nic" ]] || return 1
  [[ -f "$d/cpu_irq/runtime/rps_sock_flow_entries" && ! -L "$d/cpu_irq/runtime/rps_sock_flow_entries" ]] || return 1

  [[ -f "$d/sysctl/99-sso-rps.conf.absent" && ! -L "$d/sysctl/99-sso-rps.conf.absent" ]] || return 1
  [[ -f "$d/cpu_irq/sso-cpuirq.service.absent" && ! -L "$d/cpu_irq/sso-cpuirq.service.absent" ]] || return 1
  [[ -f "$d/cpu_irq/sso-cpuirq-restore.absent" && ! -L "$d/cpu_irq/sso-cpuirq-restore.absent" ]] || return 1

  [[ -d "$service_state_dir" && ! -L "$service_state_dir" ]] || return 1
  [[ -f "$service_state_dir/load" && ! -L "$service_state_dir/load" ]] || return 1
  [[ -f "$service_state_dir/enabled" && ! -L "$service_state_dir/enabled" ]] || return 1
  [[ -f "$service_state_dir/active" && ! -L "$service_state_dir/active" ]] || return 1
  load="$(cat "$service_state_dir/load" 2>/dev/null)" || return 1
  enabled="$(cat "$service_state_dir/enabled" 2>/dev/null)" || return 1
  active="$(cat "$service_state_dir/active" 2>/dev/null)" || return 1
  [[ "$load" == "not-found" && "$enabled" == "not-found" && "$active" == "inactive" ]]
}

uninstall_find_cpu_runtime_baseline() {
  local source=""

  source="$(backup_first_tag_in_root "$BACKUP_DIR_BASE" 'cpu_irq:rps_rfs_xps' 2>/dev/null || true)"
  if [[ -n "$source" ]] && uninstall_cpu_runtime_snapshot_is_preownership "$source"; then
    printf '%s\n' "$source"
    return 0
  fi

  if [[ -n "${SSO_DIR:-}" ]]; then
    source="$(backup_first_tag_in_root "${SSO_DIR}.bak/backups" 'cpu_irq:rps_rfs_xps' 2>/dev/null || true)"
    if [[ -n "$source" ]] && uninstall_cpu_runtime_snapshot_is_preownership "$source"; then
      printf '%s\n' "$source"
      return 0
    fi
  fi

  return 1
}

uninstall_abort_with_recovery() {
  local message="$1"
  err "$message"
  warn "Uninstall stopped before deleting SSO recovery state/backups/install files."
  warn "Fix the reported problem and run uninstall again."
  pause
}

module_uninstall() {
  header
  section "Uninstall"

  warn "This will remove SSO-owned persistent state and restore explicitly captured shared state where possible."
  warn "It can also remove packages that SSO installed (if ownership markers are present)."

  local ans=""
  if ! read_input "Are you sure you want to uninstall SSO? (y/N): " ans; then
    info "Uninstall cancelled because no interactive input was available."
    return 0
  fi
  ans="${ans,,}"
  if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
    info "Uninstall cancelled."
    pause
    return 0
  fi

  local sso_dir="${SSO_DIR}" previous_install="${SSO_DIR}.bak"
  if ! uninstall_safe_recursive_target "$STATE_DIR" \
    || ! uninstall_safe_recursive_target "$BACKUP_DIR_BASE" \
    || ! uninstall_safe_recursive_target "$sso_dir" \
    || ! uninstall_safe_recursive_target "$previous_install"; then
    err "Refusing uninstall because a recursive cleanup path is unsafe."
    err "State: $STATE_DIR | Backups: $BACKUP_DIR_BASE | Install: ${sso_dir:-<empty>} | Previous: ${previous_install:-<empty>}"
    pause
    return 0
  fi

  # Ownership baselines live outside the replaceable install tree. Retry the
  # conservative previous-install migration before making uninstall decisions;
  # never substitute "earliest retained active backup" for original ownership.
  if ! backup_migrate_ownership_baselines; then
    uninstall_abort_with_recovery "Could not reconcile durable ownership baselines."
    return 0
  fi

  local bbr_baseline="" f2b_baseline="" irq_baseline="" cpu_runtime_baseline=""
  bbr_baseline="$(backup_resource_baseline_dir bbr 2>/dev/null || true)"
  f2b_baseline="$(backup_resource_baseline_dir fail2ban 2>/dev/null || true)"
  irq_baseline="$(backup_resource_baseline_dir irqbalance 2>/dev/null || true)"

  local cpu_runtime_owned=0
  if uninstall_cpu_runtime_owned; then
    cpu_runtime_owned=1
    cpu_runtime_baseline="$(uninstall_find_cpu_runtime_baseline 2>/dev/null || true)"
    if [[ -z "$cpu_runtime_baseline" ]]; then
      uninstall_abort_with_recovery "Could not prove the pre-SSO RPS/RFS/XPS runtime baseline; refusing to remove CPU recovery state."
      return 0
    fi
  fi

  if [[ -n "$bbr_baseline" ]]; then
    info "Using pre-BBR resource baseline: $bbr_baseline"
  else
    warn "No pre-BBR baseline is available; ambiguous shared bbr.conf state will be preserved."
  fi

  local f2b_installed_by_sso=0 irqbalance_installed_by_sso=0
  [[ -f "$STATE_DIR/installed_fail2ban.marker" ]] && f2b_installed_by_sso=1
  [[ -f "$STATE_DIR/installed_irqbalance.marker" ]] && irqbalance_installed_by_sso=1

  # 1) Stop persistence before touching runtime rules so a oneshot service
  # cannot immediately re-apply state while uninstall is removing it.
  info "Stopping/disabling SSO firewall service"
  if ! uninstall_disable_sso_service sso-firewall.service; then
    uninstall_abort_with_recovery "Could not verify sso-firewall.service is stopped and disabled."
    return 0
  fi
  info "Stopping/disabling SSO CPU/IRQ service"
  if ! uninstall_disable_sso_service sso-cpuirq.service; then
    uninstall_abort_with_recovery "Could not verify sso-cpuirq.service is stopped and disabled."
    return 0
  fi

  if [[ "$cpu_runtime_owned" == "1" ]]; then
    info "Restoring pre-SSO RPS/RFS/XPS runtime state"
    if ! backup_restore_cpu_runtime "$cpu_runtime_baseline"; then
      uninstall_abort_with_recovery "Could not fully restore the captured pre-SSO RPS/RFS/XPS runtime state."
      return 0
    fi
  fi

  info "Removing SSO firewall runtime state"
  if ! remove_sso_firewall_runtime; then
    uninstall_abort_with_recovery "Some SSO firewall runtime state could not be verified as removed."
    return 0
  fi

  # 2) Package ownership is marker-driven. A failed stop/purge is a hard stop:
  # do not erase the marker/state needed for a safe retry. Never autoremove
  # unrelated dependency candidates as part of SSO ownership cleanup.
  if [[ "$f2b_installed_by_sso" == "1" ]]; then
    if ! uninstall_stop_owned_fail2ban_before_purge; then
      uninstall_abort_with_recovery "Could not stop and verify SSO-installed Fail2Ban before package purge."
      return 0
    fi
    if ! run_step "Removing Fail2Ban (purge)" apt-get purge -y fail2ban; then
      uninstall_abort_with_recovery "Fail2Ban was installed by SSO but package purge failed."
      return 0
    fi
    if ! uninstall_fail2ban_lifecycle_is_safe; then
      uninstall_abort_with_recovery "Fail2Ban remained active or its lifecycle could not be proven safe after package purge."
      return 0
    fi
    if ! uninstall_remove_fail2ban_owned_state; then
      uninstall_abort_with_recovery "Could not verify removal of SSO-owned Fail2Ban state after package purge."
      return 0
    fi
  else
    if ! uninstall_remove_fail2ban_owned_state; then
      uninstall_abort_with_recovery "Could not remove and verify SSO-owned Fail2Ban configuration."
      return 0
    fi

    local f2b_restore_rc=0
    uninstall_restore_fail2ban_service "$f2b_baseline" || f2b_restore_rc=$?
    if [[ "$f2b_restore_rc" == "2" ]]; then
      # Legacy/no service baseline: preserve current active/inactive state, but
      # an active daemon must be restarted to shed the removed SSO jail. That
      # restart is allowed only after validation succeeds.
      if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
        if ! cmd_exists fail2ban-client; then
          uninstall_abort_with_recovery "Fail2Ban is active but validation tooling is unavailable after removing SSO config."
          return 0
        fi
        if ! fail2ban-client -t; then
          uninstall_abort_with_recovery "Fail2Ban configuration is invalid after removing SSO config."
          return 0
        fi
        if ! run_step "Restarting Fail2Ban after removing SSO config" systemctl restart fail2ban; then
          uninstall_abort_with_recovery "Could not restart active Fail2Ban after removing SSO config."
          return 0
        fi
      fi
    elif [[ "$f2b_restore_rc" != "0" ]]; then
      uninstall_abort_with_recovery "Could not safely restore the captured Fail2Ban service state."
      return 0
    fi
  fi

  if [[ "$irqbalance_installed_by_sso" == "1" ]]; then
    if ! run_step "Removing irqbalance (purge)" apt-get purge -y irqbalance; then
      uninstall_abort_with_recovery "irqbalance was installed by SSO but package purge failed."
      return 0
    fi
  elif [[ -n "$irq_baseline" ]]; then
    local irq_rc=0 irq_format=""
    irq_format="$(cat "$irq_baseline/FORMAT" 2>/dev/null || true)"
    backup_restore_service_state "$irq_baseline" irqbalance.service 0 || irq_rc=$?
    if [[ "$irq_rc" == "2" && "$irq_format" != "$SSO_BACKUP_FORMAT" ]]; then
      warn "Legacy irqbalance baseline has no service lifecycle evidence; preserving current service state."
    elif [[ "$irq_rc" != "0" ]]; then
      uninstall_abort_with_recovery "Could not safely restore irqbalance.service state."
      return 0
    fi
  fi

  # 3) Remove namespaced SSO persistence only after runtime/package cleanup is
  # known. Keep launcher/state until these removals and reloads verify.
  if ! uninstall_remove_owned_persistence_files; then
    uninstall_abort_with_recovery "Some SSO-owned persistence files could not be removed."
    return 0
  fi
  if ! run_step "Reloading systemd units" systemctl daemon-reload; then
    uninstall_abort_with_recovery "systemd daemon-reload failed after removing SSO units."
    return 0
  fi

  # 4) Restore the shared legacy modules-load path from the operation-specific
  # pre-BBR baseline, then reconcile supported fq/BBR runtime state.
  if ! uninstall_restore_shared_file_baseline "$bbr_baseline"; then
    uninstall_abort_with_recovery "Could not restore the trustworthy pre-BBR shared-file baseline."
    return 0
  fi
  run_step "Applying sysctl settings (cleanup)" sysctl --system || warn "sysctl apply had errors; checking captured SSO runtime values separately."
  if [[ -n "$bbr_baseline" ]]; then
    local runtime_rc=0
    backup_restore_network_runtime "$bbr_baseline" || runtime_rc=$?
    if [[ "$runtime_rc" != "0" && "$runtime_rc" != "2" ]]; then
      uninstall_abort_with_recovery "Could not fully restore captured fq/BBR runtime state."
      return 0
    fi
  fi

  # The update installer keeps one recognized previous application at
  # ${SSO_DIR}.bak for rollback. It is SSO-owned, but delete it only after all
  # external cleanup has succeeded and only when its complete payload proves
  # that it is the installer-created fallback rather than unrelated root data.
  if [[ -e "$previous_install" || -L "$previous_install" ]]; then
    if ! uninstall_sso_payload_dir_is_recognized "$previous_install"; then
      uninstall_abort_with_recovery "Previous install fallback is not a recognized SSO payload; refusing recursive removal: $previous_install"
      return 0
    fi
    info "Removing previous SSO install fallback: $previous_install"
    if ! rm -rf -- "$previous_install" || [[ -e "$previous_install" || -L "$previous_install" ]]; then
      uninstall_abort_with_recovery "Could not remove previous SSO install fallback completely: $previous_install"
      return 0
    fi
  fi

  # 5) All external cleanup succeeded. Remove launcher and then recovery state.
  if ! uninstall_remove_launcher; then
    uninstall_abort_with_recovery "Could not remove /usr/local/bin/sso launcher."
    return 0
  fi

  if ! rm -rf "$STATE_DIR"; then
    uninstall_abort_with_recovery "Could not remove SSO state directory: $STATE_DIR"
    return 0
  fi
  if ! rm -rf "$BACKUP_DIR_BASE"; then
    uninstall_abort_with_recovery "Could not remove SSO backup directory: $BACKUP_DIR_BASE"
    return 0
  fi

  # 6) Remove the installation directory synchronously so success means the
  # artifact is actually gone, not merely scheduled for background deletion.
  info "Removing SSO installation directory: $sso_dir"
  if ! rm -rf "$sso_dir" || [[ -e "$sso_dir" || -L "$sso_dir" ]]; then
    err "Could not remove SSO installation directory completely: $sso_dir"
    pause
    return 0
  fi

  ok "SSO uninstalled."
  pause
  exit 0
}