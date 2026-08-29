#!/usr/bin/env bash
set -Eeuo pipefail

SSO_VERSION="1.1.2"
SSO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SSO_DIR/modules"
ASSETS_DIR="$SSO_DIR/assets"
STATE_DIR="/etc/sso"
BACKUP_DIR_BASE="/root/simple-server-optimizer/backups"

source "$MODULES_DIR/utils.sh"

VERSION="${SSO_VERSION:-1.1.2}"
REPO_URL="https://github.com/ach1992/simple-server-optimizer"

require_root
ensure_dirs "$STATE_DIR" "$BACKUP_DIR_BASE"

header() {
  clear || true
  line
  title "🚀 Simple Server Optimizer (SSO)  v$VERSION"
  muted "Repo: $REPO_URL"
  muted "State: $STATE_DIR"
  muted "Backups: $BACKUP_DIR_BASE"
  line
}

system_check() {
  header
  section "System Check"
  os_info
  net_info
  tcp_info
  firewall_info
  fail2ban_info
  pause
}

menu_network() {
  while true; do
    header
    section "Network Optimizations"
    menu_item "1) Enable fq + BBR (safe, auto-detect)"
    menu_item "2) Apply safe TCP tuning (backlog/timewait/keepalive)"
    menu_item "3) Show current tuning"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) module_network_enable_fq_bbr ;;
      2) module_network_apply_sysctl ;;
      3) module_network_show ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_cpu_irq() {
  while true; do
    header
    section "CPU & IRQ Optimizations"
    menu_item "1) Install & enable irqbalance"
    menu_item "2) Apply RPS/RFS/XPS (auto NIC)"
    menu_item "3) Show current IRQ/RPS status"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) module_cpu_irq_enable_irqbalance ;;
      2) module_cpu_irq_apply_rps ;;
      3) module_cpu_irq_show ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_firewall() {
  while true; do
    header
    section "Firewall / Blocklist / Whitelist"
    menu_item "1) Import bundled blocklist into SSO state"
    menu_warn "2) Apply/refresh SSO firewall rules (INPUT+OUTPUT)"
    menu_warn "3) Disable/remove SSO firewall rules"
    menu_item "4) Blacklist manager (add/remove/show)"
    menu_item "5) Whitelist manager (add/remove/show)"
    menu_item "6) Status (available + active backend)"
    menu_item "7) Common BitTorrent-port blocking (best effort)"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) module_firewall_import_blocklist ;;
      2) module_firewall_apply ;;
      3) module_firewall_disable ;;
      4) module_firewall_blacklist_menu ;;
      5) module_firewall_whitelist_menu ;;
      6) module_firewall_status ;;
      7) module_firewall_bittorrent_menu ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_fail2ban() {
  while true; do
    header
    section "Fail2Ban"
    menu_item "1) Install & enable Fail2Ban (SSH default)"
    menu_item "2) Enable nginx jail (if nginx detected)"
    menu_item "3) Sync whitelist into Fail2Ban ignoreip"
    menu_item "4) Status"
    menu_warn "5) Remove SSO Fail2Ban config (preserve service state)"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) module_fail2ban_install_ssh ;;
      2) module_fail2ban_enable_nginx ;;
      3) module_fail2ban_sync_whitelist ;;
      4) module_fail2ban_status ;;
      5) module_fail2ban_disable ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_backups() {
  while true; do
    header
    section "Backups & Rollback"
    menu_item "1) List backups"
    menu_warn "2) Rollback last backup"
    menu_warn "3) Rollback choose backup"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) module_rollback_list ;;
      2) module_rollback_last ;;
      3) module_rollback_choose ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_update() {
  while true; do
    header
    section "Update SSO"
    menu_warn "1) Update/reinstall from online source"
    menu_secondary "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        if [[ ! -f "$SSO_DIR/install.sh" ]]; then
          err "Installed install.sh is missing. Reinstall SSO using the documented installer command."
          pause
          continue
        fi

        info "Updating SSO..."
        if bash "$SSO_DIR/install.sh" --online --no-run; then
          ok "Update completed. Reloading SSO..."
          exec bash "$SSO_DIR/sso.sh"
        fi

        err "Update failed. The previous installation remains available as a fallback when an update had already started."
        pause
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main_menu() {
  while true; do
    header
    menu_item "1) System Check"
    menu_item "2) Network Optimizations"
    menu_item "3) CPU & IRQ Optimizations"
    menu_item "4) Firewall + Abuse Defender"
    menu_item "5) Fail2Ban"
    menu_item "6) Backups & Rollback"
    menu_item "7) Update"
    menu_warn "8) Uninstall (rollback + remove SSO)"
    menu_secondary "0) Exit"
    prompt_choice "Select an option" choice
    case "$choice" in
      1) system_check ;;
      2) menu_network ;;
      3) menu_cpu_irq ;;
      4) menu_firewall ;;
      5) menu_fail2ban ;;
      6) menu_backups ;;
      7) menu_update ;;
      8) module_uninstall ;;
      0) exit 0 ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

source "$MODULES_DIR/rollback.sh"
source "$MODULES_DIR/network.sh"
source "$MODULES_DIR/cpu_irq.sh"
source "$MODULES_DIR/firewall.sh"
source "$MODULES_DIR/fail2ban.sh"
source "$MODULES_DIR/uninstall.sh"

main_menu
