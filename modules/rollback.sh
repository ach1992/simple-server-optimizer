#!/usr/bin/env bash
set -Eeuo pipefail

# This module uses globals from sso.sh:
# STATE_DIR, BACKUP_DIR_BASE

backup_create_dir() {
  local d="$BACKUP_DIR_BASE/$(ts)"
  mkdir -p "$d"
  echo "$d"
}

backup_capture_sysctl() {
  local d="$1"
  mkdir -p "$d/sysctl"
  # only capture SSO-owned sysctl files
  cp -a /etc/sysctl.d/99-sso-*.conf "$d/sysctl/" 2>/dev/null || true
  cp -a /etc/modules-load.d/bbr.conf "$d/sysctl/" 2>/dev/null || true
  cp -a /etc/sysctl.d/99-sso-rps.conf "$d/sysctl/" 2>/dev/null || true
}


backup_capture_qdisc() {
  local d="$1"
  mkdir -p "$d/net"
  local nic
  nic="$(detect_nic)"
  tc qdisc show dev "$nic" > "$d/net/tc-qdisc.txt" 2>/dev/null || true
}

backup_capture_firewall() {
  local d="$1"
  mkdir -p "$d/firewall"
  cp -a /etc/systemd/system/sso-firewall.service "$d/firewall/" 2>/dev/null || true
  cp -a /usr/local/sbin/sso-firewall-restore "$d/firewall/" 2>/dev/null || true
}


backup_capture_fail2ban() {
  local d="$1"
  mkdir -p "$d/fail2ban"
  cp -a /etc/fail2ban/jail.local "$d/fail2ban/" 2>/dev/null || true
}


backup_mark() {
  local d="$1"
  local tag="$2"
  echo "$tag" > "$d/TAG"
}

backup_create() {
  local tag="$1"
  local d
  d="$(backup_create_dir)"
  backup_capture_sysctl "$d"
  backup_capture_qdisc "$d"
  backup_capture_firewall "$d"
  backup_capture_fail2ban "$d"
  backup_mark "$d" "$tag"
  ok "Backup created: $d ($tag)"
  echo "$d"
}

module_rollback_list() {
  header
  section "Backups"
  if [[ ! -d "$BACKUP_DIR_BASE" ]]; then
    warn "No backups directory."
    pause; return
  fi
  ls -1 "$BACKUP_DIR_BASE" 2>/dev/null | tail -n 50 | sed 's/^/ - /' || true
  pause
}

backup_last_dir() {
  ls -1 "$BACKUP_DIR_BASE" 2>/dev/null | sort | tail -n1 | awk -v base="$BACKUP_DIR_BASE" '{print base"/"$0}'
}

restore_from_dir() {
  local d="$1"
  [[ -d "$d" ]] || { err "Backup not found: $d"; return 1; }

  warn "Restoring SSO-owned configs from: $d"
  warn "This rollback is limited to files/services created by SSO."

  # sysctl: remove current SSO files then restore captured ones
  rm -f /etc/sysctl.d/99-sso-*.conf 2>/dev/null || true
  rm -f /etc/sysctl.d/99-sso-rps.conf 2>/dev/null || true
  if compgen -G "$d/sysctl/99-sso-*.conf" >/dev/null; then
    cp -a "$d/sysctl/99-sso-*.conf" /etc/sysctl.d/ 2>/dev/null || true
  fi
  if [[ -f "$d/sysctl/99-sso-rps.conf" ]]; then
    cp -a "$d/sysctl/99-sso-rps.conf" /etc/sysctl.d/ 2>/dev/null || true
  fi
  if [[ -f "$d/sysctl/bbr.conf" ]]; then
    cp -a "$d/sysctl/bbr.conf" /etc/modules-load.d/bbr.conf 2>/dev/null || true
  fi
  sysctl --system >/dev/null 2>&1 || true

  # CPU/IRQ persistence service restore
  if [[ -f "$d/sysctl/99-sso-rps.conf" ]] || [[ -f "/etc/systemd/system/sso-cpuirq.service" ]]; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now sso-cpuirq.service 2>/dev/null || true
  fi

  # firewall persistence artifacts
  rm -f /etc/systemd/system/sso-firewall.service 2>/dev/null || true
  rm -f /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  if [[ -f "$d/firewall/sso-firewall.service" ]]; then
    cp -a "$d/firewall/sso-firewall.service" /etc/systemd/system/ 2>/dev/null || true
  fi
  if [[ -f "$d/firewall/sso-firewall-restore" ]]; then
    cp -a "$d/firewall/sso-firewall-restore" /usr/local/sbin/ 2>/dev/null || true
    chmod +x /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  fi
  systemctl daemon-reload 2>/dev/null || true
  if [[ -f /etc/systemd/system/sso-firewall.service ]]; then
    systemctl enable --now sso-firewall.service 2>/dev/null || true
  else
    systemctl disable --now sso-firewall.service 2>/dev/null || true
  fi

  # fail2ban jail.local restore (only our managed file)
  if [[ -f "$d/fail2ban/jail.local" ]]; then
    ensure_dirs /etc/fail2ban
    cp -a "$d/fail2ban/jail.local" /etc/fail2ban/jail.local 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true
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
  restore_from_dir "$d"
}

module_rollback_choose() {
  header
  section "Rollback choose backup"
  local list
  list="$(ls -1 "$BACKUP_DIR_BASE" 2>/dev/null | sort | tail -n 30 || true)"
  if [[ -z "${list:-}" ]]; then
    err "No backups found."
    pause; return
  fi
  echo "$list" | nl -w2 -s') '
  echo "0) Back"
  local idx
  idx="$(prompt_choice "Select number")"
  [[ "$idx" == "0" ]] && return
  local selected
  selected="$(echo "$list" | sed -n "${idx}p")"
  if [[ -z "${selected:-}" ]]; then
    err "Invalid selection."
    pause; return
  fi
  restore_from_dir "$BACKUP_DIR_BASE/$selected"
}
