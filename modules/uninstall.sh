#!/usr/bin/env bash
set -Eeuo pipefail

# Uninstall SSO-owned state while restoring only shared/operator state that a
# current-format backup explicitly captured before SSO touched it.

uninstall_restore_shared_file_baseline() {
  local baseline="$1"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"

  if [[ -n "$baseline" ]]; then
    if backup_restore_file_state "$baseline/sysctl/bbr.conf" "$modules_load_dir/bbr.conf"; then
      return 0
    fi
  fi

  if [[ -e "$modules_load_dir/bbr.conf" || -L "$modules_load_dir/bbr.conf" ]]; then
    warn "No trustworthy v2 baseline for /etc/modules-load.d/bbr.conf; preserving the current file rather than guessing ownership."
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

uninstall_restore_fail2ban_service() {
  local baseline="$1"
  [[ -n "$baseline" ]] || return 2

  local desired_active=""
  desired_active="$(backup_service_state_value "$baseline" fail2ban.service active 2>/dev/null || true)"
  if [[ "$desired_active" == "active" ]] && cmd_exists fail2ban-client; then
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
  read_input "Are you sure you want to uninstall SSO? (y/N): " ans
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

  local baseline=""
  baseline="$(backup_first_current_format_dir 2>/dev/null || true)"
  if [[ -n "$baseline" ]]; then
    info "Using earliest current-format backup as shared-state baseline: $baseline"
  else
    warn "No current-format baseline backup is available; ambiguous non-namespaced files will be preserved."
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
  local f2b_managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  if [[ "$f2b_installed_by_sso" == "1" ]]; then
    if ! run_step "Removing Fail2Ban (purge)" apt-get purge -y fail2ban; then
      uninstall_abort_with_recovery "Fail2Ban was installed by SSO but package purge failed."
      return 0
    fi
    rm -f "$f2b_managed" "${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}" 2>/dev/null || true
  else
    rm -f "$f2b_managed" "${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}" 2>/dev/null || true

    local f2b_restore_rc=0
    uninstall_restore_fail2ban_service "$baseline" || f2b_restore_rc=$?
    if [[ "$f2b_restore_rc" == "2" ]]; then
      if cmd_exists fail2ban-client; then
        if ! fail2ban-client -t; then
          uninstall_abort_with_recovery "Fail2Ban configuration is invalid after removing SSO config."
          return 0
        fi
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
          if ! run_step "Restarting Fail2Ban after removing SSO config" systemctl restart fail2ban; then
            uninstall_abort_with_recovery "Could not restart active Fail2Ban after removing SSO config."
            return 0
          fi
        fi
      fi
    elif [[ "$f2b_restore_rc" != "0" ]]; then
      uninstall_abort_with_recovery "Could not fully restore the captured Fail2Ban service state."
      return 0
    fi
  fi

  if [[ "$irqbalance_installed_by_sso" == "1" ]]; then
    if ! run_step "Removing irqbalance (purge)" apt-get purge -y irqbalance; then
      uninstall_abort_with_recovery "irqbalance was installed by SSO but package purge failed."
      return 0
    fi
  elif [[ -n "$baseline" ]]; then
    local irq_rc=0
    backup_restore_service_state "$baseline" irqbalance.service 0 || irq_rc=$?
    if [[ "$irq_rc" != "0" && "$irq_rc" != "2" ]]; then
      uninstall_abort_with_recovery "Could not fully restore irqbalance.service state."
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

  # 4) Restore the shared legacy modules-load path only from explicit baseline
  # evidence, then reconcile persistent and supported fq/BBR runtime state.
  uninstall_restore_shared_file_baseline "$baseline"
  run_step "Applying sysctl settings (cleanup)" sysctl --system || warn "sysctl apply had errors; checking captured SSO runtime values separately."
  if [[ -n "$baseline" ]]; then
    local runtime_rc=0
    backup_restore_network_runtime "$baseline" || runtime_rc=$?
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
