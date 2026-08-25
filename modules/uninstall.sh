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

  local active enabled
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

  local sso_dir="${SSO_DIR}"
  if ! uninstall_safe_recursive_target "$STATE_DIR" \
    || ! uninstall_safe_recursive_target "$BACKUP_DIR_BASE" \
    || ! uninstall_safe_recursive_target "$sso_dir"; then
    err "Refusing uninstall because a recursive cleanup path is unsafe."
    err "State: $STATE_DIR | Backups: $BACKUP_DIR_BASE | Install: ${sso_dir:-<empty>}"
    pause
    return 0
  fi

  # Baselines are resource-specific. The first v2 snapshot may have been made
  # only after a legacy release had already taken ownership of a shared file
  # or service, so format version is not a chronology signal.
  local bbr_baseline="" f2b_baseline="" irq_baseline=""
  bbr_baseline="$(backup_first_tag_dir 'network:fq_bbr' 2>/dev/null || true)"
  f2b_baseline="$(backup_first_tag_dir 'fail2ban:*' 2>/dev/null || true)"
  irq_baseline="$(backup_first_tag_dir 'cpu_irq:irqbalance' 2>/dev/null || true)"

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

  info "Removing SSO firewall runtime state"
  if ! remove_sso_firewall_runtime; then
    uninstall_abort_with_recovery "Some SSO firewall runtime state could not be verified as removed."
    return 0
  fi

  # 2) Package ownership is marker-driven. A failed purge is a hard stop: do
  # not erase the marker/state needed for a safe retry. Never autoremove
  # unrelated dependency candidates as part of SSO ownership cleanup.
  if [[ "$f2b_installed_by_sso" == "1" ]]; then
    if ! run_step "Removing Fail2Ban (purge)" apt-get purge -y fail2ban; then
      uninstall_abort_with_recovery "Fail2Ban was installed by SSO but package purge failed."
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
