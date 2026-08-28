#!/usr/bin/env bash
set -Eeuo pipefail

REPO_SLUG="ach1992/simple-server-optimizer"
RELEASE_REF="main"
INSTALL_DIR="/root/simple-server-optimizer"
STATE_DIR="/etc/sso"
LAUNCHER_PATH="/usr/local/bin/sso"

SOURCE_PATH="${BASH_SOURCE[0]:-$0}"
SOURCE_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" && pwd)"

PAYLOAD_FILES=(
  install.sh
  sso.sh
  modules/utils.sh
  modules/network.sh
  modules/cpu_irq.sh
  modules/firewall.sh
  modules/fail2ban.sh
  modules/rollback.sh
  modules/uninstall.sh
  assets/whitelist-default.ipv4
)

c_reset="\033[0m"
c_red="\033[31m"
c_grn="\033[32m"
c_ylw="\033[33m"
c_cyn="\033[36m"

say() { printf "%b\n" "$*"; }
err() { say "${c_red}[!]${c_reset} $*" >&2; }
ok()  { say "${c_grn}[+]${c_reset} $*"; }
info(){ say "${c_cyn}[*]${c_reset} $*"; }
warn(){ say "${c_ylw}[!]${c_reset} $*" >&2; }

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
    return 1
  fi
}

ensure_tools() {
  command -v curl >/dev/null 2>&1 && return 0
  warn "curl not found. Installing curl and CA certificates..."
  apt-get update -y >/dev/null 2>&1 || return 1
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1
}

has_payload() {
  local root="$1"
  local rel
  for rel in "${PAYLOAD_FILES[@]}"; do
    [[ -f "$root/$rel" && ! -L "$root/$rel" ]] || return 1
  done
  return 0
}

validate_payload() {
  local root="$1"
  has_payload "$root" || {
    err "Incomplete SSO payload: $root"
    return 1
  }

  local scripts=("$root/install.sh" "$root/sso.sh" "$root"/modules/*.sh)
  bash -n "${scripts[@]}" || {
    err "Payload contains invalid Bash syntax."
    return 1
  }
}

copy_payload() {
  local source="$1"
  local target="$2"
  local rel

  mkdir -p "$target/modules" "$target/assets" || return 1
  for rel in "${PAYLOAD_FILES[@]}"; do
    cp -a -- "$source/$rel" "$target/$rel" || return 1
  done

  if [[ -f "$source/assets/blocklist-ip.ipv4" && ! -L "$source/assets/blocklist-ip.ipv4" ]]; then
    cp -a -- "$source/assets/blocklist-ip.ipv4" "$target/assets/blocklist-ip.ipv4" || return 1
  fi
}

create_launcher() {
  mkdir -p -- "$(dirname -- "$LAUNCHER_PATH")" || return 1
  cat >"$LAUNCHER_PATH" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail
exec bash $(printf '%q' "$INSTALL_DIR/sso.sh") "\$@"
EOF_LAUNCHER
  chmod 755 "$LAUNCHER_PATH"
}

write_install_state() {
  mkdir -p -- "$STATE_DIR" || return 1
  printf '%s\n' "$INSTALL_DIR" > "$STATE_DIR/install_dir"
}

activate_payload() {
  local stage="$1"
  local backup="${INSTALL_DIR}.bak"
  local had_previous=0

  mkdir -p -- "$(dirname -- "$INSTALL_DIR")" || return 1

  if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || {
      err "Install path exists but is not a normal directory: $INSTALL_DIR"
      return 1
    }
    had_previous=1
    rm -rf -- "$backup" || return 1
    mv -- "$INSTALL_DIR" "$backup" || return 1

    if [[ -d "$backup/backups" ]]; then
      cp -a -- "$backup/backups" "$stage/backups" || {
        mv -- "$backup" "$INSTALL_DIR" 2>/dev/null || true
        return 1
      }
    fi
  fi

  if ! mv -- "$stage" "$INSTALL_DIR"; then
    if [[ "$had_previous" -eq 1 && -d "$backup" && ! -e "$INSTALL_DIR" ]]; then
      mv -- "$backup" "$INSTALL_DIR" 2>/dev/null || true
    fi
    return 1
  fi

  chmod 755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/sso.sh" || return 1
  write_install_state || return 1
  create_launcher || return 1

  if [[ "$had_previous" -eq 0 ]]; then
    rm -rf -- "$backup" 2>/dev/null || true
  fi
}

install_payload() {
  local source="$1"
  local parent stage

  validate_payload "$source" || return 1

  parent="$(dirname -- "$INSTALL_DIR")"
  mkdir -p -- "$parent" || return 1
  stage="$(mktemp -d "${INSTALL_DIR}.new.XXXXXX")" || return 1

  if ! copy_payload "$source" "$stage" || ! validate_payload "$stage"; then
    rm -rf -- "$stage"
    return 1
  fi

  if ! activate_payload "$stage"; then
    rm -rf -- "$stage" 2>/dev/null || true
    return 1
  fi
}

install_local() {
  info "Installing from local payload: $SOURCE_DIR"

  if [[ "$SOURCE_DIR" == "$INSTALL_DIR" ]]; then
    validate_payload "$SOURCE_DIR" || return 1
    chmod 755 "$INSTALL_DIR/install.sh" "$INSTALL_DIR/sso.sh" || return 1
    write_install_state || return 1
    create_launcher || return 1
    return 0
  fi

  install_payload "$SOURCE_DIR"
}

curl_fetch() {
  local url="$1"
  local out="$2"
  curl -fL --retry 3 --retry-delay 1 -sS "$url" -o "$out" || return 1
  [[ -s "$out" ]]
}

download_online() {
  ensure_tools || {
    err "curl is required for online update/install."
    return 1
  }

  local tmp base rel
  tmp="$(mktemp -d)" || return 1
  base="https://raw.githubusercontent.com/${REPO_SLUG}/${RELEASE_REF}"
  mkdir -p "$tmp/modules" "$tmp/assets" || { rm -rf -- "$tmp"; return 1; }

  info "Downloading SSO from ${REPO_SLUG}@${RELEASE_REF}..."
  for rel in "${PAYLOAD_FILES[@]}"; do
    if ! curl_fetch "${base}/${rel}" "$tmp/$rel"; then
      err "Failed to download: $rel"
      rm -rf -- "$tmp"
      return 1
    fi
  done

  curl_fetch "${base}/assets/blocklist-ip.ipv4" "$tmp/assets/blocklist-ip.ipv4" 2>/dev/null || true

  if ! install_payload "$tmp"; then
    rm -rf -- "$tmp"
    return 1
  fi
  rm -rf -- "$tmp"
}

run_sso() {
  exec bash "$INSTALL_DIR/sso.sh"
}

usage() {
  cat <<'EOF_USAGE'
Usage: sudo bash install.sh [--local|--online] [--no-run]

  --local   install/update from the directory containing this install.sh
  --online  download the configured release source, then install/update
  --no-run  finish without opening the SSO menu
EOF_USAGE
}

choose_mode() {
  local choice=""
  if has_payload "$SOURCE_DIR"; then
    say ""
    say "${c_cyn}Simple Server Optimizer - Installer${c_reset}"
    say "Local payload: $SOURCE_DIR"
    say "Install path:  $INSTALL_DIR"
    say ""
    say "1) Install/update from LOCAL files"
    say "2) Install/update from ONLINE source"
    say "0) Exit"
    read_input "Select an option: " choice
    case "${choice:-}" in
      1) printf '%s\n' local ;;
      2) printf '%s\n' online ;;
      0) printf '%s\n' exit ;;
      *) return 1 ;;
    esac
  else
    printf '%s\n' online
  fi
}

main() {
  local mode=""
  local run_after=1

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --local) mode="local" ;;
      --online) mode="online" ;;
      --no-run) run_after=0 ;;
      -h|--help) usage; return 0 ;;
      *) err "Unknown option: $1"; usage; return 1 ;;
    esac
    shift
  done

  need_root || return 1

  if [[ -z "$mode" ]]; then
    mode="$(choose_mode)" || { err "Invalid choice."; return 1; }
  fi

  case "$mode" in
    local) install_local || return 1 ;;
    online) download_online || return 1 ;;
    exit) return 0 ;;
    *) err "Invalid install mode."; return 1 ;;
  esac

  ok "SSO installation/update completed."
  if [[ "$run_after" -eq 1 ]]; then
    run_sso
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
