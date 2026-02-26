#!/usr/bin/env bash
set -Eeuo pipefail

SSO_TABLE_INET="inet sso"
SSO_TABLE_IP="ip sso"
SSO_SET_BLOCK="sso_block_v4"
SSO_SET_WHITE="sso_white_v4"
SSO_CHAIN_IN="sso_in"
SSO_CHAIN_OUT="sso_out"

STATE_BLOCKLIST="$STATE_DIR/blocklist-ip.ipv4"
STATE_WHITELIST="$STATE_DIR/whitelist-ip.ipv4"
STATE_BTFLAG="$STATE_DIR/bittorrent-block.enabled"

ASSET_BLOCKLIST="$ASSETS_DIR/blocklist-ip.ipv4"
ASSET_WHITEDEFAULT="$ASSETS_DIR/whitelist-default.ipv4"

ensure_default_whitelist() {
  ensure_dirs "$STATE_DIR"
  if [[ ! -f "$STATE_WHITELIST" ]]; then
    cp -a "$ASSET_WHITEDEFAULT" "$STATE_WHITELIST"
  fi
  # guarantee required default
  if ! grep -qx "10.235.0.0/19" "$STATE_WHITELIST" 2>/dev/null; then
    echo "10.235.8.0/21" >> "$STATE_WHITELIST"
  fi
  # dedupe
  awk 'NF && $0 !~ /^#/' "$STATE_WHITELIST" | sed 's/[[:space:]]//g' | sort -u > "$STATE_WHITELIST.tmp"
  mv "$STATE_WHITELIST.tmp" "$STATE_WHITELIST"
}


ensure_state_blocklist() {
  ensure_dirs "$STATE_DIR"
  # Create empty blocklist if missing (so user can add entries via menu)
  if [[ ! -f "$STATE_BLOCKLIST" ]]; then
    : > "$STATE_BLOCKLIST"
  fi
  # Deduplicate / sanitize
  sanitize_iplist < "$STATE_BLOCKLIST" > "$STATE_BLOCKLIST.tmp" || true
  mv "$STATE_BLOCKLIST.tmp" "$STATE_BLOCKLIST"
}

sanitize_iplist() {
  # stdin -> stdout: keep ipv4/cidr lines, remove comments/spaces
  awk '
    BEGIN{FS=""; OFS=""}
    {
      gsub(/\r/,"",$0)
      sub(/[[:space:]]*[#;].*$/,"",$0)
      gsub(/[[:space:]]/,"",$0)
      if ($0=="") next
      print $0
    }
  ' | sort -u
}

module_firewall_import_blocklist() {
  header
  section "Import blocklist from assets"
  ensure_dirs "$STATE_DIR"
  ensure_default_whitelist

  if [[ ! -f "$ASSET_BLOCKLIST" ]]; then
    err "Missing assets/blocklist-ip.ipv4"
    err "Place your merged file in: $ASSET_BLOCKLIST"
    pause; return
  fi

  local d
  d="$(backup_create "firewall:import_blocklist")"

  sanitize_iplist < "$ASSET_BLOCKLIST" > "$STATE_BLOCKLIST"
  ok "Imported into: $STATE_BLOCKLIST"
  ok "Entries: $(wc -l < "$STATE_BLOCKLIST" | tr -d " ")"
  firewall_persist_enable

  ok "Backup: $d"
  pause
}

detect_firewall_backend() {
  # IMPORTANT: must print ONLY the backend token to stdout (used by callers).
  # Any diagnostics should go to stderr to avoid breaking case-matching.
  if cmd_exists nft; then
    # ensure nftables is actually usable (kernel + ruleset access)
    if nft list ruleset >/dev/null 2>&1; then
      echo "nft"
      return 0
    fi
    echo "nft-unusable" >&2
    # fall through to try iptables+ipset as a fallback
  fi

  if cmd_exists iptables && cmd_exists ipset; then
    echo "ipset"
    return 0
  fi

  echo "none"
}




firewall_persist_enable() {
  ensure_dirs "$STATE_DIR" /usr/local/sbin /etc/systemd/system
  # store install dir for restore scripts
  echo "$SSO_DIR" > "$STATE_DIR/install_dir" 2>/dev/null || true

  cat > /usr/local/sbin/sso-firewall-restore <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
SSO_DIR="$INSTALL_DIR"
MODULES_DIR="$SSO_DIR/modules"
ASSETS_DIR="$SSO_DIR/assets"
# shellcheck source=/dev/null
source "$MODULES_DIR/utils.sh"
# shellcheck source=/dev/null
source "$MODULES_DIR/firewall.sh"

backend="$(detect_firewall_backend)"
case "$backend" in
  nft) nft_apply ;;
  ipset) ipset_apply ;;
  *) echo "No supported firewall backend." >&2; exit 1 ;;
esac
EOS
  chmod +x /usr/local/sbin/sso-firewall-restore

  cat > /etc/systemd/system/sso-firewall.service <<'EOF'
[Unit]
Description=SSO Firewall (blocklist/whitelist)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sso-firewall-restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  run_step "Reloading systemd units" systemctl daemon-reload || warn "systemd daemon-reload failed (continuing)."
  run_step "Enabling firewall persistence" systemctl enable --now sso-firewall.service || warn "Could not enable sso-firewall.service (continuing)."
}

firewall_persist_disable() {
  run_step "Disabling firewall persistence" systemctl disable --now sso-firewall.service || warn "Could not disable sso-firewall.service (continuing)."
  rm -f /etc/systemd/system/sso-firewall.service 2>/dev/null || true
  rm -f /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  run_step "Reloading systemd units" systemctl daemon-reload || warn "systemd daemon-reload failed (continuing)."
}

nft_apply() {
  ensure_default_whitelist
  ensure_state_blocklist

# clean previous SSO table/rules (recreate fresh)
if nft list table inet sso >/dev/null 2>&1; then
  nft flush table inet sso 2>/dev/null || true
  nft delete table inet sso 2>/dev/null || true
fi


  # Build ruleset (idempotent)
  nft add table inet sso 2>/dev/null || true
  nft "add set inet sso $SSO_SET_BLOCK { type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true
  nft "add set inet sso $SSO_SET_WHITE { type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || true

  # chains
  nft "add chain inet sso $SSO_CHAIN_IN { type filter hook input priority 0; policy accept; }" 2>/dev/null || true
  nft "add chain inet sso $SSO_CHAIN_OUT { type filter hook output priority 0; policy accept; }" 2>/dev/null || true

  # flush chains to avoid duplicates
  nft "flush chain inet sso $SSO_CHAIN_IN" 2>/dev/null || true
  nft "flush chain inet sso $SSO_CHAIN_OUT" 2>/dev/null || true

  # load sets: flush then add
  nft "flush set inet sso $SSO_SET_BLOCK" 2>/dev/null || true
  nft "flush set inet sso $SSO_SET_WHITE" 2>/dev/null || true

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    nft "add element inet sso $SSO_SET_BLOCK { $ip }" 2>/dev/null || true
  done < "$STATE_BLOCKLIST"

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    nft "add element inet sso $SSO_SET_WHITE { $ip }" 2>/dev/null || true
  done < "$STATE_WHITELIST"

  # rules: whitelist priority
  nft "add rule inet sso $SSO_CHAIN_IN ip saddr @${SSO_SET_WHITE} accept" 2>/dev/null || true
  # Optional: block BitTorrent traffic by common ports (best-effort)
  if [[ -f "$STATE_BTFLAG" ]]; then
    nft "add rule inet sso $SSO_CHAIN_IN tcp dport { 6881-6889, 6969, 51413 } drop" 2>/dev/null || true
    nft "add rule inet sso $SSO_CHAIN_IN udp dport { 6881-6889, 6969, 51413 } drop" 2>/dev/null || true
  fi
  nft "add rule inet sso $SSO_CHAIN_IN ip saddr @${SSO_SET_BLOCK} drop" 2>/dev/null || true

  nft "add rule inet sso $SSO_CHAIN_OUT ip daddr @${SSO_SET_WHITE} accept" 2>/dev/null || true
  if [[ -f "$STATE_BTFLAG" ]]; then
    nft "add rule inet sso $SSO_CHAIN_OUT tcp dport { 6881-6889, 6969, 51413 } drop" 2>/dev/null || true
    nft "add rule inet sso $SSO_CHAIN_OUT udp dport { 6881-6889, 6969, 51413 } drop" 2>/dev/null || true
  fi
  nft "add rule inet sso $SSO_CHAIN_OUT ip daddr @${SSO_SET_BLOCK} drop" 2>/dev/null || true

  nft list table inet sso >/dev/null 2>&1 || { err "nftables apply did not create expected table."; return 1; }
  ok "Applied nftables backend (INPUT+OUTPUT)."
  return 0
}

ipset_apply() {
  ensure_default_whitelist
  ensure_state_blocklist

  # recreate sets (remove old types/settings)
  ipset destroy sso_block_v4 2>/dev/null || true
  ipset destroy sso_white_v4 2>/dev/null || true

  ipset create sso_block_v4 hash:net family inet maxelem 200000 2>/dev/null || true
  ipset create sso_white_v4 hash:net family inet maxelem 200000 2>/dev/null || true
  ipset flush sso_block_v4 2>/dev/null || true
  ipset flush sso_white_v4 2>/dev/null || true

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    ipset add sso_block_v4 "$ip" 2>/dev/null || true
  done < "$STATE_BLOCKLIST"

  while read -r ip; do
    [[ -n "$ip" ]] || continue
    ipset add sso_white_v4 "$ip" 2>/dev/null || true
  done < "$STATE_WHITELIST"

  # iptables rules (idempotent)
  iptables -N SSO_IN 2>/dev/null || true
  iptables -N SSO_OUT 2>/dev/null || true
  iptables -F SSO_IN 2>/dev/null || true
  iptables -F SSO_OUT 2>/dev/null || true

  iptables -C INPUT -j SSO_IN 2>/dev/null || iptables -I INPUT 1 -j SSO_IN
  iptables -C OUTPUT -j SSO_OUT 2>/dev/null || iptables -I OUTPUT 1 -j SSO_OUT

  # whitelist priority
  iptables -A SSO_IN  -m set --match-set sso_white_v4 src -j RETURN
  if [[ -f "$STATE_BTFLAG" ]]; then
    iptables -A SSO_IN  -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP
    iptables -A SSO_IN  -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP
  fi
  iptables -A SSO_IN  -m set --match-set sso_block_v4 src -j DROP
  iptables -A SSO_IN  -j RETURN

  iptables -A SSO_OUT -m set --match-set sso_white_v4 dst -j RETURN
  if [[ -f "$STATE_BTFLAG" ]]; then
    iptables -A SSO_OUT -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP
    iptables -A SSO_OUT -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP
  fi
  iptables -A SSO_OUT -m set --match-set sso_block_v4 dst -j DROP
  iptables -A SSO_OUT -j RETURN

  ipset list sso_block_v4 >/dev/null 2>&1 || { err "ipset apply did not create expected sets."; return 1; }
  iptables -S SSO_IN >/dev/null 2>&1 || { err "iptables apply did not create expected chains."; return 1; }
  ok "Applied iptables+ipset backend (INPUT+OUTPUT)."
  return 0
}

module_firewall_apply() {
  header
  section "Apply blocklist (INPUT+OUTPUT default)"
  ensure_default_whitelist

  if [[ ! -f "$STATE_BLOCKLIST" ]]; then
    warn "State blocklist not found. Creating empty one so you can add IPs via Blacklist manager."
    : > "$STATE_BLOCKLIST"
  fi

  local d
  d="$(backup_create "firewall:apply")"

  local backend
  backend="$(detect_firewall_backend)"
  case "$backend" in
    nft) if ! run_step "Applying firewall rules (nftables)" nft_apply; then pause; return; fi ;;
    ipset) if ! run_step "Applying firewall rules (iptables+ipset)" ipset_apply; then pause; return; fi ;;
    *)
      if cmd_exists nft; then
        warn "nft command exists but nftables seems unusable on this system (kernel/module or permissions)."
        warn "Try: apt-get install nftables && modprobe nf_tables (then re-run), or use iptables+ipset."
      fi
      err "No supported firewall backend found (need nft OR iptables+ipset)."
      pause; return
      ;;
  esac

  firewall_persist_enable

  ok "Backup: $d"
  pause
}

module_firewall_disable() {
  header
  section "Disable SSO firewall rules"
  local d
  d="$(backup_create "firewall:disable")"

  firewall_persist_disable

  if cmd_exists nft; then
    nft delete table inet sso 2>/dev/null || true
  fi
  if cmd_exists iptables; then
    iptables -D INPUT -j SSO_IN 2>/dev/null || true
    iptables -D OUTPUT -j SSO_OUT 2>/dev/null || true
    iptables -F SSO_IN 2>/dev/null || true
    iptables -F SSO_OUT 2>/dev/null || true
    iptables -X SSO_IN 2>/dev/null || true
    iptables -X SSO_OUT 2>/dev/null || true
  fi
  if cmd_exists ipset; then
    ipset destroy sso_block_v4 2>/dev/null || true
    ipset destroy sso_white_v4 2>/dev/null || true
  fi
  ok "SSO firewall disabled. (Backup: $d)"
  pause
}


module_firewall_blacklist_menu() {
  ensure_state_blocklist
  while true; do
    header
    section "Blacklist manager"
    echo "Blacklist file: $STATE_BLOCKLIST"
    echo "1) Show blacklist"
    echo "2) Add IP/CIDR"
    echo "3) Remove IP/CIDR"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header; section "Blacklist"
        nl -w2 -s') ' "$STATE_BLOCKLIST" || true
        pause
        ;;
      2)
        printf "Enter IP/CIDR to blacklist: "
        read_input "" ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "${ip:-}" ]]; then err "Empty."; pause; continue; fi
        if ! validate_ipv4_or_cidr "$ip"; then
          err "Invalid IPv4 or CIDR. Examples: 1.2.3.4  |  1.2.3.0/24"
          pause; continue
        fi
        echo "$ip" >> "$STATE_BLOCKLIST"
        ensure_state_blocklist
        ok "Added."
        warn "Re-apply firewall (menu option 2) to activate rules."
        pause
        ;;
      3)
        printf "Enter IP/CIDR to remove: "
        read_input "" ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "${ip:-}" ]]; then err "Empty."; pause; continue; fi
        if ! validate_ipv4_or_cidr "$ip"; then
          err "Invalid IPv4 or CIDR. Examples: 1.2.3.4  |  1.2.3.0/24"
          pause; continue
        fi
        grep -vxF "$ip" "$STATE_BLOCKLIST" > "$STATE_BLOCKLIST.tmp" || true
        mv "$STATE_BLOCKLIST.tmp" "$STATE_BLOCKLIST"
        ensure_state_blocklist
        ok "Removed (if existed)."
        warn "Re-apply firewall (menu option 2) to update active rules."
        pause
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

module_firewall_whitelist_menu() {
  ensure_default_whitelist
  while true; do
    header
    section "Whitelist manager"
    echo "Whitelist file: $STATE_WHITELIST"
    echo "1) Show whitelist"
    echo "2) Add IP/CIDR"
    echo "3) Remove IP/CIDR"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header; section "Whitelist"
        nl -w2 -s') ' "$STATE_WHITELIST" || true
        pause
        ;;
      2)
        printf "Enter IP/CIDR to whitelist: "
        read_input "" ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "${ip:-}" ]]; then err "Empty."; pause; continue; fi
        if ! validate_ipv4_or_cidr "$ip"; then
          err "Invalid IPv4 or CIDR. Examples: 1.2.3.4  |  1.2.3.0/24"
          pause; continue
        fi
        echo "$ip" >> "$STATE_WHITELIST"
        ensure_default_whitelist
        ok "Added."
        pause
        ;;
      3)
        printf "Enter IP/CIDR to remove: "
        read_input "" ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "${ip:-}" ]]; then err "Empty."; pause; continue; fi
        if ! validate_ipv4_or_cidr "$ip"; then
          err "Invalid IPv4 or CIDR. Examples: 1.2.3.4  |  1.2.3.0/24"
          pause; continue
        fi
        grep -vxF "$ip" "$STATE_WHITELIST" > "$STATE_WHITELIST.tmp" || true
        mv "$STATE_WHITELIST.tmp" "$STATE_WHITELIST"
        ensure_default_whitelist
        ok "Removed (if existed)."
        pause
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

module_firewall_status() {
  header
  section "Firewall status"
  local backend
  backend="$(detect_firewall_backend)"
  info "Backend: $backend"
  ensure_default_whitelist
  ensure_state_blocklist
  info "Blocklist entries: $( [[ -f "$STATE_BLOCKLIST" ]] && wc -l < "$STATE_BLOCKLIST" | tr -d " " || echo 0)"
  info "Whitelist entries: $(wc -l < "$STATE_WHITELIST" | tr -d " ")"
  info "BitTorrent block: $( [[ -f "$STATE_BTFLAG" ]] && echo "ENABLED" || echo "disabled" )"
  echo ""
  if [[ "$backend" == "nft" ]]; then
    nft list table inet sso 2>/dev/null | sed -n '1,120p' || true
  elif [[ "$backend" == "ipset" ]]; then
    ipset list sso_block_v4 2>/dev/null | sed -n '1,40p' || true
    iptables -S SSO_IN 2>/dev/null || true
    iptables -S SSO_OUT 2>/dev/null || true
  fi
  pause
}

module_firewall_bittorrent_menu() {
  header
  section "BitTorrent traffic block"
  ensure_dirs "$STATE_DIR"

  if [[ -f "$STATE_BTFLAG" ]]; then
    warn "BitTorrent blocking is currently ENABLED."
    echo "1) Disable BitTorrent blocking"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        rm -f "$STATE_BTFLAG" 2>/dev/null || true
        ok "BitTorrent blocking disabled."
        warn "Re-apply firewall (option 2) to update active rules."
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  else
    info "BitTorrent blocking is currently disabled."
    echo "1) Enable BitTorrent blocking"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        : > "$STATE_BTFLAG"
        ok "BitTorrent blocking enabled."
        warn "Re-apply firewall (option 2) to activate rules."
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  fi
  pause
}
