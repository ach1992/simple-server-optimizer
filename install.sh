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
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
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

  curl_fetch "${base}/sso.sh" "$tmp/sso.sh"
  # basic sanity check
  grep -q "^#!/" "$tmp/sso.sh" || { err "Downloaded sso.sh looks invalid."; return 1; }

  for f in utils.sh network.sh cpu_irq.sh firewall.sh fail2ban.sh rollback.sh; do
    curl_fetch "${base}/modules/${f}" "$tmp/modules/${f}"
  done

  curl_fetch "${base}/assets/whitelist-default.ipv4" "$tmp/assets/whitelist-default.ipv4"
  # blocklist in repo may be optional; don't fail if missing
  curl -fL -sS "${base}/assets/blocklist-ip.ipv4" -o "$tmp/assets/blocklist-ip.ipv4" >/dev/null 2>&1 || true

  # atomically replace install dir content
  rm -rf "$INSTALL_DIR.bak" 2>/dev/null || true
  [[ -d "$INSTALL_DIR" ]] && mv "$INSTALL_DIR" "$INSTALL_DIR.bak" 2>/dev/null || true
  mkdir -p "$INSTALL_DIR"
  cp -a "$tmp/sso.sh" "$INSTALL_DIR/sso.sh"
  mkdir -p "$INSTALL_DIR/modules" "$INSTALL_DIR/assets"
  cp -a "$tmp/modules/." "$INSTALL_DIR/modules/"
  cp -a "$tmp/assets/." "$INSTALL_DIR/assets/"

  chmod +x "$INSTALL_DIR/sso.sh"

  # store install dir for persistence scripts
  mkdir -p /etc/ssoptimizer
  echo "$INSTALL_DIR" > /etc/ssoptimizer/install_dir 2>/dev/null || true

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
INSTALL_DIR_FILE="/etc/ssoptimizer/install_dir"
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
  # اگر فایل‌ها از قبل داخل پوشه نصب موجود باشد، فقط همان موقع سؤال آف/آنلاین بپرس
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
      1) create_launcher; run_sso ;;
      2) download_online; create_launcher; run_sso ;;
      0) exit 0 ;;
      *) err "Invalid choice."; exit 1 ;;
    esac
  else
    # هیچ فایل آفلاینی نیست → بدون سؤال آنلاین نصب کن
    info "No offline payload found in $INSTALL_DIR → installing ONLINE..."
    download_online
    create_launcher
    run_sso
  fi
}

need_root

menu
