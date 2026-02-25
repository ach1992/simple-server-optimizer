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
  cp -a /etc/sysctl.d "$d/sysctl/" 2>/dev/null || true
  cp -a /etc/sysctl.conf "$d/sysctl/" 2>/dev/null || true
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
  if cmd_exists nft; then
    nft list ruleset > "$d/firewall/nft.rules" 2>/dev/null || true
  fi
  if cmd_exists iptables; then
    iptables-save > "$d/firewall/iptables.rules" 2>/dev/null || true
  fi
  if cmd_exists ipset; then
    ipset save > "$d/firewall/ipset.save" 2>/dev/null || true
  fi
}

backup_capture_fail2ban() {
  local d="$1"
  mkdir -p "$d/fail2ban"
  cp -a /etc/fail2ban "$d/fail2ban/" 2>/dev/null || true
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

  warn "Restoring from: $d"
  warn "This will restore sysctl, firewall and fail2ban configs captured."
  # sysctl restore
  if [[ -d "$d/sysctl/sysctl.d" ]]; then
    rm -rf /etc/sysctl.d.bak.sso 2>/dev/null || true
    cp -a /etc/sysctl.d /etc/sysctl.d.bak.sso 2>/dev/null || true
    rm -rf /etc/sysctl.d
    cp -a "$d/sysctl/sysctl.d" /etc/sysctl.d
  fi
  if [[ -f "$d/sysctl/sysctl.conf" ]]; then
    cp -a "$d/sysctl/sysctl.conf" /etc/sysctl.conf
  fi
  sysctl --system >/dev/null 2>&1 || true

  # firewall restore
  if [[ -f "$d/firewall/nft.rules" ]] && cmd_exists nft; then
    nft -f "$d/firewall/nft.rules" 2>/dev/null || true
  fi
  if [[ -f "$d/firewall/ipset.save" ]] && cmd_exists ipset; then
    ipset restore < "$d/firewall/ipset.save" 2>/dev/null || true
  fi
  if [[ -f "$d/firewall/iptables.rules" ]] && cmd_exists iptables-restore; then
    iptables-restore < "$d/firewall/iptables.rules" 2>/dev/null || true
  fi

  # fail2ban restore
  if [[ -d "$d/fail2ban/fail2ban" ]]; then
    rm -rf /etc/fail2ban
    cp -a "$d/fail2ban/fail2ban" /etc/fail2ban
    systemctl restart fail2ban 2>/dev/null || true
  fi

  ok "Restore completed."
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
