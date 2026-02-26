#!/usr/bin/env bash
set -Eeuo pipefail

# Uninstall SSO: rollback SSO-owned changes, remove installed packages (if installed by SSO),
# and delete SSO files/state/backups.

module_uninstall() {
  header
  section "Uninstall"

  warn "This will attempt to rollback changes made by SSO and remove SSO files."
  warn "It can also remove packages that SSO installed (if markers are present)."

  local ans=""
  read_input "Are you sure you want to uninstall SSO? (y/N): " ans
  ans="${ans,,}"
  if [[ "$ans" != "y" && "$ans" != "yes" ]]; then
    info "Uninstall cancelled."
    pause
    return 0
  fi

  # 1) Rollback from last backup if available
  local last=""
  last="$(backup_last_dir 2>/dev/null || true)"
  if [[ -n "${last:-}" && -d "$last" ]]; then
    info "Restoring from latest backup: $last"
    if restore_from_dir "$last"; then
      ok "Rollback - done"
    else
      err "Rollback - failed (continuing)"
    fi
  else
    warn "No backups found. Performing best-effort cleanup of SSO-owned files."
    # Remove SSO sysctl files and module load entry
    rm -f /etc/sysctl.d/99-sso-*.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/99-sso-rps.conf 2>/dev/null || true
    rm -f /etc/modules-load.d/bbr.conf 2>/dev/null || true
    run_step "Applying sysctl settings (cleanup)" sysctl --system || warn "sysctl apply had errors (continuing)."
  fi

  # 2) Disable and remove services/scripts created by SSO
  info "Stopping/disabling SSO firewall service"
  systemd_disable_now_safe sso-firewall.service
  ok "Stopping/disabling SSO firewall service - done"
  info "Stopping/disabling SSO CPU/IRQ service"
  systemd_disable_now_safe sso-cpuirq.service
  ok "Stopping/disabling SSO CPU/IRQ service - done"
  rm -f /etc/systemd/system/sso-firewall.service /etc/systemd/system/sso-cpuirq.service 2>/dev/null || true
  rm -f /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  run_step "Reloading systemd units" systemctl daemon-reload || true

  # 3) Remove packages installed by SSO (only if marker files exist)
  if [[ -f "$STATE_DIR/installed_fail2ban.marker" ]]; then
    run_step "Removing Fail2Ban (purge)" apt-get purge -y fail2ban || warn "Fail2Ban removal failed (continuing)."
    run_step "Autoremoving packages" apt-get autoremove -y || true
  fi
  if [[ -f "$STATE_DIR/installed_irqbalance.marker" ]]; then
    run_step "Removing irqbalance (purge)" apt-get purge -y irqbalance || warn "irqbalance removal failed (continuing)."
    run_step "Autoremoving packages" apt-get autoremove -y || true
  fi

  # 4) Remove state + backups
  run_step "Removing state directory" rm -rf "$STATE_DIR" || true
  run_step "Removing backup directory" rm -rf "$BACKUP_DIR_BASE" || true

  # 5) Remove installed script directory (self-delete)
  local sso_dir="${SSO_DIR}"
  info "Removing SSO installation directory: $sso_dir"
  # Defer deletion to avoid issues with current shell reading files
  ( sleep 1; rm -rf "$sso_dir" ) >/dev/null 2>&1 & disown || true

  ok "SSO uninstalled."
  warn "If you are currently running from the installation directory, it will be removed shortly."
  pause
  exit 0
}
