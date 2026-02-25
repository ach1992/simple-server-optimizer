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

# Run a command while showing progress + colored success/failure.
run_step() {
  local msg="$1"; shift
  info "$msg"
  if "$@" >/dev/null 2>&1; then
    ok "$msg - done"
    return 0
  fi
  err "$msg - failed"
  return 1
}

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
  run_step "Updating package index" apt-get update -y || true
  run_step "Installing curl + CA certs" apt-get install -y curl ca-certificates || true
  command -v curl >/dev/null 2>&1 || { err "curl install failed."; exit 1; }
}

has_offline_payload() {
  [[ -f "$INSTALL_DIR/sso.sh" ]] && [[ -d "$INSTALL_DIR/modules" ]] && [[ -d "$INSTALL_DIR/assets" ]]
}

download_online() {
  ensure_tools
  mkdir -p "$INSTALL_DIR"

  local base="https://raw.githubusercontent.com/${REPO_SLUG}/${BRANCH}"

  info "Downloading latest SSO from GitHub (online)..."

  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp" 2>/dev/null || true' RETURN

  mkdir -p "$tmp/modules" "$tmp/assets"

  curl_fetch() {
    local url="$1"
    local out="$2"
    # retry helps on flaky networks
    curl -fL --retry 5 --retry-delay 1 --retry-all-errors -sS "$url" -o "$out"
    [[ -s "$out" ]] || { err "Downloaded file is empty: $url"; return 1; }
  }

  run_step "Downloading sso.sh" curl_fetch "${base}/sso.sh" "$tmp/sso.sh" || return 1
  # basic sanity check
  grep -q "^#!/" "$tmp/sso.sh" || { err "Downloaded sso.sh looks invalid."; return 1; }

  # ✅ FIX: download install.sh from the correct path (repo root).
  # If it fails for any reason, fallback to copying the currently running installer (if available).
  if ! run_step "Downloading install.sh" curl_fetch "${base}/install.sh" "$tmp/install.sh"; then
    warn "Could not download install.sh from GitHub; trying to save the running installer as fallback..."
    if [[ -n "${0:-}" && -f "${0}" ]]; then
      cp -a "${0}" "$tmp/install.sh" || { err "Fallback copy of install.sh failed."; return 1; }
      ok "Fallback: saved running installer as install.sh - done"
    else
      err "Fallback failed: cannot locate running installer path."
      return 1
    fi
  fi

  # modules
  for f in utils.sh network.sh cpu_irq.sh firewall.sh fail2ban.sh rollback.sh uninstall.sh; do
    run_step "Downloading modules/${f}" curl_fetch "${base}/modules/${f}" "$tmp/modules/${f}" || return 1
  done

  run_step "Downloading whitelist-default.ipv4" curl_fetch "${base}/assets/whitelist-default.ipv4" "$tmp/assets/whitelist-default.ipv4" || return 1
  # blocklist in repo may be optional; don't fail if missing
  curl -fL -sS "${base}/assets/blocklist-ip.ipv4" -o "$tmp/assets/blocklist-ip.ipv4" >/dev/null 2>&1 || true

  # atomically replace install dir content
  rm -rf "$INSTALL_DIR.bak" 2>/dev/null || true
  [[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "$INSTALL_DIR.bak" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  cp -a "$tmp/sso.sh" "$INSTALL_DIR/sso.sh"
  cp -a "$tmp/install.sh" "$INSTALL_DIR/install.sh"
  mkdir -p "$INSTALL_DIR/modules" "$INSTALL_DIR/assets"
  cp -a "$tmp/modules/." "$INSTALL_DIR/modules/"
  cp -a "$tmp/assets/." "$INSTALL_DIR/assets/"

  run_step "Setting executable bit" chmod +x "$INSTALL_DIR/sso.sh" "$INSTALL_DIR/install.sh" || true

  # store install dir for persistence scripts
  mkdir -p /etc/sso
  echo "$INSTALL_DIR" > /etc/sso/install_dir 2>/dev/null || true

  ok "Online download complete."
  warn "NOTE: Put your blocklist at: $INSTALL_DIR/assets/blocklist-ip.ipv4 (offline/managed) or keep it in repo."
}

run_sso() {
  exec bash "$INSTALL_DIR/sso.sh"
}

create_launcher() {
  # Create a simple command to run SSO without re-installing
  local target="$INSTALL_DIR/sso.sh"
  if [[ ! -f "$target" ]]; then
    return 0
  fi
  tee /usr/local/bin/sso >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR_FILE="/etc/sso/install_dir"
if [[ -r "$INSTALL_DIR_FILE" ]]; then
  INSTALL_DIR="$(cat "$INSTALL_DIR_FILE" 2>/dev/null || true)"
else
  INSTALL_DIR="/root/simple-server-optimizer"
fi
exec bash "${INSTALL_DIR}/sso.sh" "$@"
EOF
  chmod +x /usr/local/bin/sso 2>/dev/null || true
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
    read_input "Select an option: " choice
    case "${choice:-}" in
      1) create_launcher; run_sso ;;
      2) download_online; create_launcher; run_sso ;;
      0) exit 0 ;;
      *) err "Invalid choice."; exit 1 ;;
    esac
  else
    info "No offline payload found in $INSTALL_DIR → installing ONLINE..."
    download_online
    create_launcher
    run_sso
  fi
}

need_root
menu
