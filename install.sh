#!/usr/bin/env bash
set -Eeuo pipefail

REPO_SLUG="ach1992/simple-server-optimizer"
BRANCH="main"
INSTALL_DIR="/root/simple-server-optimizer"

# ---------- colors ----------
c_reset="\033[0m"
c_red="\033[31m"
c_grn="\033[32m"
c_ylw="\033[33m"
c_cyn="\033[36m"

say() { printf "%b\n" "$*"; }
err() { say "${c_red}[!]${c_reset} $*"; }
ok()  { say "${c_grn}[+]${c_reset} $*"; }
info(){ say "${c_cyn}[*]${c_reset} $*"; }
warn(){ say "${c_ylw}[!]${c_reset} $*"; }

# Read from TTY even if script is started via pipe (e.g. curl | bash)
read_input() {
  local prompt="${1:-}"
  local -n __out="$2"
  [[ -n "$prompt" ]] && printf "%s" "$prompt"
  if [[ -r /dev/tty ]]; then
    IFS= read -r __out </dev/tty || true
  else
    IFS= read -r __out || true
  fi
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Please run as root."
    exit 1
  fi
}

ensure_tools() {
  if command -v curl >/dev/null 2>&1; then return 0; fi
  warn "curl not found. Installing..."
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y curl >/dev/null 2>&1 || true
  command -v curl >/dev/null 2>&1 || { err "curl install failed."; exit 1; }
}

has_offline_payload() {
  [[ -f "$INSTALL_DIR/sso.sh" ]] && [[ -d "$INSTALL_DIR/modules" ]] && [[ -d "$INSTALL_DIR/assets" ]]
}

download_online() {
  ensure_tools
  mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/modules" "$INSTALL_DIR/assets"
  local base="https://raw.githubusercontent.com/${REPO_SLUG}/${BRANCH}"

  info "Downloading latest SSO from GitHub..."
  curl -fsSL "${base}/sso.sh" -o "$INSTALL_DIR/sso.sh"

  for f in utils.sh network.sh cpu_irq.sh firewall.sh fail2ban.sh rollback.sh; do
    curl -fsSL "${base}/modules/${f}" -o "$INSTALL_DIR/modules/${f}"
  done

  curl -fsSL "${base}/assets/whitelist-default.ipv4" -o "$INSTALL_DIR/assets/whitelist-default.ipv4"

  chmod +x "$INSTALL_DIR/sso.sh"
  ok "Online download complete."
  warn "NOTE: Put your blocklist at: $INSTALL_DIR/assets/blocklist-ip.ipv4 (offline) or keep it in repo."
}

run_sso() {
  exec bash "$INSTALL_DIR/sso.sh"
}

menu() {
  if has_offline_payload; then
    say ""
    say "${c_cyn}Simple Server Optimizer - Installer${c_reset}"
    say "Install dir: $INSTALL_DIR"
    say ""
    say "${c_grn}[+]${c_reset} Offline payload detected."
    say "1) Use OFFLINE (local files)"
    say "2) Use ONLINE  (download latest from GitHub)"
    say "0) Exit"
    local choice=""
    read_input "Select: " choice
    case "${choice:-}" in
      1) run_sso ;;
      2) download_online; run_sso ;;
      0) exit 0 ;;
      *) err "Invalid choice."; exit 1 ;;
    esac
  else
    info "No offline payload found in $INSTALL_DIR → installing ONLINE..."
    download_online
    run_sso
  fi
}

need_root

menu
