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
  [[ -n "$prompt" ]] && printf "%s" "$prompt"
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
  local label="${1:-Select}"
  local ans=""
  while true; do
    read_input "${label}: " ans
    ans="${ans:-}"
    if [[ "$ans" =~ ^[0-9]+$ ]]; then
      echo "$ans"
      return 0
    fi
    err "Please enter a number."
  done
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
