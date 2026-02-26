#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- colors ----------
c_reset="\033[0m"
c_bold="\033[1m"
c_dim="\033[2m"
c_red="\033[31m"
c_grn="\033[32m"
c_ylw="\033[33m"
c_cyn="\033[36m"
c_wht="\033[97m"
c_mag="\033[35m"

say()   { printf "%b\n" "$*"; }
ok()    { say "${c_grn}[+]${c_reset} $*"; }
info()  { say "${c_cyn}[*]${c_reset} $*"; }
warn()  { say "${c_ylw}[!]${c_reset} $*"; }
err()   { say "${c_red}[x]${c_reset} $*"; }
title() { say "${c_bold}${c_mag}$*${c_reset}"; }
muted() { say "${c_dim}$*${c_reset}"; }

line() { say "${c_dim}------------------------------------------------------------${c_reset}"; }
section() { say "${c_bold}$*${c_reset}"; line; }

# Read from TTY even if script is started via pipe (e.g. curl | bash)
read_input() {
  local prompt="${1:-}"
  local -n __out="$2"
  if [[ -n "$prompt" ]]; then
    if [[ -w /dev/tty ]]; then
      printf "%s" "$prompt" >/dev/tty
    else
      printf "%s" "$prompt" >&2
    fi
  fi
  if [[ -r /dev/tty ]]; then
    IFS= read -r __out </dev/tty || true
  else
    IFS= read -r __out || true
  fi
}

pause() {
  local _
  read_input "Press Enter to continue..." _
}

prompt_choice() {
  local label="${1:-Select an option}"
  local -n __out="$2"
  local ans=""

  while true; do
    if [[ -w /dev/tty ]]; then
      printf "\n" >/dev/tty
    else
      printf "\n" >&2
    fi

    read_input "${label}: " ans
    ans="${ans:-}"

    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      __out="$ans"
      return 0
    fi

    if [[ -w /dev/tty ]]; then
      printf "%b\n" "${c_red}[x]${c_reset} Please enter a number." >/dev/tty
    else
      printf "%b\n" "${c_red}[x]${c_reset} Please enter a number." >&2
    fi
  done
}

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

# ---------- systemd helpers ----------
systemd_load_state() {
  local unit="$1"
  systemctl show -p LoadState --value "$unit" 2>/dev/null || true
}

systemd_unit_exists() {
  local unit="$1"
  local st
  st="$(systemd_load_state "$unit")"
  [[ -n "$st" && "$st" != "not-found" ]]
}

systemd_disable_now_safe() {
  # Best-effort disable/stop/unmask, treating "not-found" as success.
  local unit="$1"
  local st
  st="$(systemd_load_state "$unit")"

  # If masked, unmask first so stop/disable won't error.
  systemctl unmask "$unit" >/dev/null 2>&1 || true
  systemctl stop "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
  systemctl reset-failed "$unit" >/dev/null 2>&1 || true

  # Consider it a success if unit is gone or disabled.
  st="$(systemd_load_state "$unit")"
  if [[ -z "$st" || "$st" == "not-found" ]]; then
    return 0
  fi
  return 0
}


require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root."
    exit 1
  fi
}

ensure_dirs() {
  for d in "$@"; do
    mkdir -p "$d"
  done
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

ts() { date +"%Y%m%d-%H%M%S"; }

# ---------- info helpers ----------
os_info() {
  local pretty kernel
  pretty="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  kernel="$(uname -r)"
  info "OS: $pretty"
  info "Kernel: $kernel"
  info "Uptime: $(uptime -p 2>/dev/null || true)"
}

detect_nic() {
  # default route interface
  local nic
  nic="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -z "${nic:-}" ]]; then
    nic="$(ip -o link show | awk -F': ' '{print $2}' | grep -Ev '^(lo|docker|veth|br-|virbr|tun|tap)' | head -n1)"
  fi
  echo "${nic:-eth0}"
}

net_info() {
  local nic
  nic="$(detect_nic)"
  info "NIC: $nic"
  ip -s link show dev "$nic" 2>/dev/null | sed -n '1,8p' || true
  if ip link show "$nic" >/dev/null 2>&1; then
    tc qdisc show dev "$nic" 2>/dev/null || true
  else
    warn "NIC not found: $nic (skipping tc qdisc info)"
  fi
}

tcp_info() {
  local cc
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "n/a")"
  info "qdisc: $(sysctl -n net.core.default_qdisc 2>/dev/null || echo "n/a")"
  info "congestion: ${cc}"
  info "BBR: $([[ "$cc" == "bbr" ]] && echo "ACTIVE" || echo "NOT ACTIVE")"
  info "available cc: $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "n/a")"
}

firewall_info() {
  if cmd_exists nft; then
    info "Firewall: nftables available"
  elif cmd_exists iptables; then
    info "Firewall: iptables available"
  else
    warn "Firewall tools not found"
  fi
}

fail2ban_info() {
  if cmd_exists fail2ban-client; then
    info "Fail2Ban: installed"
    fail2ban-client status 2>/dev/null | sed -n '1,6p' || true
  else
    info "Fail2Ban: not installed"
  fi
}

# ---------- IP/CIDR validation ----------
is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  local -a o
  read -r -a o <<<"$ip"
  [[ ${#o[@]} -eq 4 ]] || return 1
  local n
  for n in "${o[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 0 && n <= 255 )) || return 1
  done
  return 0
}

is_ipv4_cidr() {
  local cidr="$1"
  [[ "$cidr" == */* ]] || return 1
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"
  is_ipv4 "$ip" || return 1
  [[ "$mask" =~ ^[0-9]+$ ]] || return 1
  (( mask >= 0 && mask <= 32 )) || return 1
  return 0
}

validate_ipv4_or_cidr() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1
  # reject anything with spaces
  [[ "$v" == "${v//[[:space:]]/}" ]] || return 1
  if [[ "$v" == */* ]]; then
    is_ipv4_cidr "$v"
  else
    is_ipv4 "$v"
  fi
}

