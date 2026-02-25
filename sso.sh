#!/usr/bin/env bash
set -Eeuo pipefail

SSO_VERSION="1.0.0"
SSO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SSO_DIR/modules"
ASSETS_DIR="$SSO_DIR/assets"
STATE_DIR="/etc/sso"
BACKUP_DIR_BASE="/root/simple-server-optimizer/backups"

source "$MODULES_DIR/utils.sh"

VERSION="${SSO_VERSION:-1.0.0}"
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
    echo "1) Enable fq + BBR (safe, auto-detect)"
    echo "2) Apply safe TCP tuning (backlog/timewait/keepalive)"
    echo "3) Show current tuning"
    echo "0) Back"
    choice="$(prompt_choice)"
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
    echo "1) Install & enable irqbalance"
    echo "2) Apply RPS/RFS/XPS (auto NIC)"
    echo "3) Show current IRQ/RPS status"
    echo "0) Back"
    choice="$(prompt_choice)"
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
    echo "1) Import blocklist from assets -> state (dedupe)"
    echo "2) Apply blocklist (DEFAULT: INPUT+OUTPUT)"
    echo "3) Remove/Disable SSO firewall rules (rollback firewall only)"
    echo "4) Whitelist manager (add/remove/show)"
    echo "5) Status (counts + active backend)"
    echo "6) Block BitTorrent traffic (ports + common tracker ports)"
    echo "0) Back"
    choice="$(prompt_choice)"
    case "$choice" in
      1) module_firewall_import_blocklist ;;
      2) module_firewall_apply ;;
      3) module_firewall_disable ;;
      4) module_firewall_whitelist_menu ;;
      5) module_firewall_status ;;
      6) module_firewall_bittorrent_menu ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_fail2ban() {
  while true; do
    header
    section "Fail2Ban"
    echo "1) Install & enable Fail2Ban (SSH default)"
    echo "2) Enable nginx jail (if nginx detected)"
    echo "3) Sync whitelist into Fail2Ban ignoreip"
    echo "4) Status"
    echo "5) Disable Fail2Ban changes (rollback f2b only)"
    echo "0) Back"
    choice="$(prompt_choice)"
    case "$choice" in
      1) module_fail2ban_install_ssh ;;
      2) module_fail2ban_enable_nginx ;;
      3) module_fail2ban_sync_whitelist ;;
      4) module_fail2ban_status ;;
      5) module_fail2ban_rollback ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

menu_backups() {
  while true; do
    header
    section "Backups & Rollback"
    echo "1) List backups"
    echo "2) Rollback last backup"
    echo "3) Rollback choose backup"
    echo "0) Back"
    choice="$(prompt_choice)"
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
    section "Update / Mode"
    echo "1) Offline/Online note"
    echo "2) Re-run installer (online/offline selector)"
    echo "0) Back"
    choice="$(prompt_choice)"
    case "$choice" in
      1)
        info "If files exist in /root/simple-server-optimizer, installer can run offline."
        info "Online mode downloads latest scripts. Blocklist file is not automatically downloaded."
        pause
        ;;
      2) bash "$SSO_DIR/install.sh" ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

main_menu() {
  while true; do
    header
    echo "1) System Check"
    echo "2) Network Optimizations"
    echo "3) CPU & IRQ Optimizations"
    echo "4) Firewall / Blocklist"
    echo "5) Fail2Ban"
    echo "6) Backups & Rollback"
    echo "7) Update / Mode"
    echo "8) Uninstall (rollback + remove SSO)"
    echo "0) Exit"
    choice="$(prompt_choice)"
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

# load module entrypoints
source "$MODULES_DIR/rollback.sh"
source "$MODULES_DIR/network.sh"
source "$MODULES_DIR/cpu_irq.sh"
source "$MODULES_DIR/firewall.sh"
source "$MODULES_DIR/fail2ban.sh"
source "$MODULES_DIR/uninstall.sh"

main_menu
