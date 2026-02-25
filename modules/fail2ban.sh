#!/usr/bin/env bash
set -Eeuo pipefail

F2B_JAIL_LOCAL="/etc/fail2ban/jail.local"

detect_nginx() {
  command -v nginx >/dev/null 2>&1 || systemctl is-enabled nginx >/dev/null 2>&1
}

ensure_fail2ban_installed() {
  if cmd_exists fail2ban-client; then return 0; fi
  run_step "Updating package index" apt-get update -y || true
  if ! dpkg -s fail2ban >/dev/null 2>&1; then
    run_step "Installing Fail2Ban" apt-get install -y fail2ban || true
    if dpkg -s fail2ban >/dev/null 2>&1; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      touch "$STATE_DIR/installed_fail2ban.marker" 2>/dev/null || true
    fi
  fi
  cmd_exists fail2ban-client
}



ensure_jail_local() {
  ensure_dirs /etc/fail2ban
  if [[ ! -f "$F2B_JAIL_LOCAL" ]]; then
    # create a sane default
    write_base_jail
  else
    # make sure it is writable/readable
    touch "$F2B_JAIL_LOCAL" 2>/dev/null || true
  fi
}

write_base_jail() {
  ensure_dirs /etc/fail2ban

  local banaction="iptables-multiport"
  if cmd_exists nft; then
    # fail2ban on Debian/Ubuntu generally supports nftables actions
    banaction="nftables-multiport"
  fi

  tee "$F2B_JAIL_LOCAL" >/dev/null <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ${banaction}

[sshd]
enabled = true
EOF
}

module_fail2ban_install_ssh() {
  header
  section "Fail2Ban: install & enable (SSH)"
  local d
  d="$(backup_create "fail2ban:install_ssh")"

  if ! ensure_fail2ban_installed; then
    err "Failed to install Fail2Ban."
    pause; return
  fi

  write_base_jail
  run_step "Enabling Fail2Ban service" systemctl enable --now fail2ban || warn "Could not enable Fail2Ban (continuing)."
  run_step "Restarting Fail2Ban" systemctl restart fail2ban || warn "Could not restart Fail2Ban (continuing)."

  ok "Fail2Ban enabled (sshd). Backup: $d"
  pause
}

module_fail2ban_enable_nginx() {
  header
  section "Fail2Ban: enable nginx jail"
  local d
  d="$(backup_create "fail2ban:enable_nginx")"

  if ! ensure_fail2ban_installed; then
    err "Fail2Ban not installed."
    pause; return
  fi

  if ! detect_nginx; then
    warn "nginx not detected. Skipping."
    pause; return
  fi

  ensure_jail_local

  # Basic nginx auth / bad bots jails depend on distro filters; keep simple:
  if ! grep -q "^\[nginx-http-auth\]" "$F2B_JAIL_LOCAL" 2>/dev/null; then
    cat >> "$F2B_JAIL_LOCAL" <<'EOF'

[nginx-http-auth]
enabled = true
EOF
  fi

  run_step "Restarting Fail2Ban" systemctl restart fail2ban || warn "Could not restart Fail2Ban (continuing)."
  ok "nginx-http-auth jail enabled. Backup: $d"
  pause
}

module_fail2ban_sync_whitelist() {
  header
  section "Fail2Ban: sync ignoreip from SSO whitelist"
  local d
  d="$(backup_create "fail2ban:sync_whitelist")"

  if ! ensure_fail2ban_installed; then
    err "Fail2Ban not installed."
    pause; return
  fi

  ensure_default_whitelist

  local ips
  ips="$(tr '\n' ' ' < "$STATE_WHITELIST" | xargs echo || true)"

  ensure_jail_local

  # replace or add ignoreip
  if grep -q "^ignoreip" "$F2B_JAIL_LOCAL"; then
    sed -i "s|^ignoreip.*|ignoreip = ${ips}|" "$F2B_JAIL_LOCAL"
  else
    sed -i "1iignoreip = ${ips}" "$F2B_JAIL_LOCAL"
  fi

  run_step "Restarting Fail2Ban" systemctl restart fail2ban || warn "Could not restart Fail2Ban (continuing)."
  ok "Synced ignoreip. Backup: $d"
  pause
}

module_fail2ban_status() {
  header
  section "Fail2Ban status"
  if ! cmd_exists fail2ban-client; then
    warn "Fail2Ban not installed."
    pause; return
  fi
  info "Fetching Fail2Ban status..."
  fail2ban-client status 2>/dev/null || { err "Failed to read Fail2Ban status."; }
  pause
}

module_fail2ban_rollback() {
  header
  section "Fail2Ban rollback (restore via backups menu recommended)"
  warn "For full rollback, use: Backups & Rollback -> rollback last/choose."
  warn "This option only stops fail2ban service."
  run_step "Stopping Fail2Ban" systemctl stop fail2ban || warn "Could not stop Fail2Ban (continuing)."
  ok "Fail2Ban stopped."
  pause
}
