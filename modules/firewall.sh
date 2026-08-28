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

sanitize_iplist() {
  awk '
    {
      gsub(/\r/, "", $0)
      sub(/[[:space:]]*[#;].*$/, "", $0)
      gsub(/[[:space:]]/, "", $0)
      if ($0 != "") print $0
    }
  ' | sort -u
}

normalize_iplist_source() {
  local source="$1"
  local destination="$2"
  local label="${3:-IP list}"
  local tmp entry

  tmp="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! sanitize_iplist < "$source" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if ! validate_ipv4_or_cidr "$entry"; then
      err "$label contains an invalid IPv4/CIDR entry: $entry"
      rm -f -- "$tmp"
      return 1
    fi
  done < "$tmp"

  mv -- "$tmp" "$destination"
}

ensure_default_whitelist() {
  local candidate
  ensure_dirs "$STATE_DIR"

  if [[ -e "$STATE_WHITELIST" || -L "$STATE_WHITELIST" ]]; then
    [[ -f "$STATE_WHITELIST" && ! -L "$STATE_WHITELIST" ]] || {
      err "Whitelist state is not a normal file: $STATE_WHITELIST"
      return 1
    }
  fi

  candidate="$(mktemp "${STATE_WHITELIST}.candidate.XXXXXX")" || return 1

  if [[ -f "$STATE_WHITELIST" ]]; then
    cat -- "$STATE_WHITELIST" > "$candidate" || { rm -f -- "$candidate"; return 1; }
  else
    [[ -f "$ASSET_WHITEDEFAULT" && ! -L "$ASSET_WHITEDEFAULT" ]] || {
      err "Missing default whitelist asset: $ASSET_WHITEDEFAULT"
      rm -f -- "$candidate"
      return 1
    }
    cat -- "$ASSET_WHITEDEFAULT" > "$candidate" || { rm -f -- "$candidate"; return 1; }
  fi

  if ! grep -qx "10.235.0.0/19" "$candidate" 2>/dev/null; then
    printf '%s\n' "10.235.0.0/19" >> "$candidate"
  fi

  if ! normalize_iplist_source "$candidate" "$STATE_WHITELIST" "Whitelist"; then
    rm -f -- "$candidate"
    return 1
  fi
  rm -f -- "$candidate"
}

ensure_state_blocklist() {
  ensure_dirs "$STATE_DIR"
  if [[ ! -e "$STATE_BLOCKLIST" ]]; then
    : > "$STATE_BLOCKLIST"
  fi
  [[ -f "$STATE_BLOCKLIST" && ! -L "$STATE_BLOCKLIST" ]] || {
    err "Blocklist state is not a normal file: $STATE_BLOCKLIST"
    return 1
  }
  normalize_iplist_source "$STATE_BLOCKLIST" "$STATE_BLOCKLIST" "Blocklist"
}

module_firewall_import_blocklist() {
  header
  section "Import blocklist from assets"
  ensure_dirs "$STATE_DIR"

  if [[ ! -f "$ASSET_BLOCKLIST" || -L "$ASSET_BLOCKLIST" ]]; then
    err "Missing assets/blocklist-ip.ipv4"
    err "Place your merged file in: $ASSET_BLOCKLIST"
    pause
    return 0
  fi

  if ! ensure_default_whitelist; then
    pause
    return 0
  fi

  local d
  d="$(backup_create "firewall:import_blocklist")"

  if ! normalize_iplist_source "$ASSET_BLOCKLIST" "$STATE_BLOCKLIST" "Blocklist asset"; then
    err "Blocklist import rejected; existing state was not replaced."
    pause
    return 0
  fi

  ok "Imported into: $STATE_BLOCKLIST"
  ok "Entries: $(wc -l < "$STATE_BLOCKLIST" | tr -d " ")"

  local active_backend
  active_backend="$(firewall_active_backend)"
  if [[ "$active_backend" == "none" ]]; then
    info "Import only changed saved SSO state; the firewall remains disabled until you choose Apply/refresh."
  else
    warn "SSO firewall is currently active using $active_backend. Saved state changed, but active rules were not replaced automatically."
    info "Choose Apply/refresh SSO firewall rules to load the imported list into the active firewall."
  fi

  ok "Backup: $d"
  pause
}

detect_firewall_backend() {
  if cmd_exists nft; then
    if nft list ruleset >/dev/null 2>&1; then
      echo "nft"
      return 0
    fi
    echo "nft-unusable" >&2
  fi

  if cmd_exists iptables && cmd_exists ipset; then
    echo "ipset"
    return 0
  fi

  echo "none"
}

firewall_active_backend() {
  if cmd_exists nft && nft list table inet sso >/dev/null 2>&1; then
    echo "nft"
    return 0
  fi

  if cmd_exists ipset && cmd_exists iptables \
    && ipset list sso_block_v4 >/dev/null 2>&1 \
    && ipset list sso_white_v4 >/dev/null 2>&1 \
    && iptables -S SSO_IN >/dev/null 2>&1 \
    && iptables -S SSO_OUT >/dev/null 2>&1; then
    echo "ipset"
    return 0
  fi

  echo "none"
}

firewall_persist_enable() {
  ensure_dirs "$STATE_DIR" /usr/local/sbin /etc/systemd/system
  printf '%s\n' "$SSO_DIR" > "$STATE_DIR/install_dir" || return 1

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
  chmod 755 /usr/local/sbin/sso-firewall-restore || return 1

  cat > /etc/systemd/system/sso-firewall.service <<'EOF_UNIT'
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
EOF_UNIT

  run_step "Reloading systemd units" systemctl daemon-reload || return 1
  run_step "Enabling firewall persistence" systemctl enable --now sso-firewall.service || return 1
}

firewall_persist_disable() {
  info "Disabling firewall persistence"
  systemd_disable_now_safe sso-firewall.service
  rm -f /etc/systemd/system/sso-firewall.service /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  run_step "Reloading systemd units" systemctl daemon-reload || warn "systemd daemon-reload failed."
}

nft_add_file_elements() {
  local set_name="$1"
  local file="$2"
  local elements

  [[ -s "$file" ]] || return 0
  elements="$(paste -sd, "$file")"
  nft "add element inet sso $set_name { $elements }"
}

nft_apply() {
  ensure_default_whitelist || return 1
  ensure_state_blocklist || return 1

  if nft list table inet sso >/dev/null 2>&1; then
    nft delete table inet sso >/dev/null 2>&1 || {
      err "Could not replace the existing SSO nftables table."
      return 1
    }
  fi

  nft add table inet sso >/dev/null 2>&1 || return 1
  nft "add set inet sso $SSO_SET_BLOCK { type ipv4_addr; flags interval; auto-merge; }" >/dev/null 2>&1 || return 1
  nft "add set inet sso $SSO_SET_WHITE { type ipv4_addr; flags interval; auto-merge; }" >/dev/null 2>&1 || return 1
  nft "add chain inet sso $SSO_CHAIN_IN { type filter hook input priority 0; policy accept; }" >/dev/null 2>&1 || return 1
  nft "add chain inet sso $SSO_CHAIN_OUT { type filter hook output priority 0; policy accept; }" >/dev/null 2>&1 || return 1

  nft_add_file_elements "$SSO_SET_BLOCK" "$STATE_BLOCKLIST" >/dev/null 2>&1 || {
    err "nftables rejected one or more blocklist entries."
    return 1
  }
  nft_add_file_elements "$SSO_SET_WHITE" "$STATE_WHITELIST" >/dev/null 2>&1 || {
    err "nftables rejected one or more whitelist entries."
    return 1
  }

  nft "add rule inet sso $SSO_CHAIN_IN ip saddr @${SSO_SET_WHITE} accept" >/dev/null 2>&1 || return 1
  if [[ -f "$STATE_BTFLAG" ]]; then
    nft "add rule inet sso $SSO_CHAIN_IN tcp dport { 6881-6889, 6969, 51413 } drop" >/dev/null 2>&1 || return 1
    nft "add rule inet sso $SSO_CHAIN_IN udp dport { 6881-6889, 6969, 51413 } drop" >/dev/null 2>&1 || return 1
  fi
  nft "add rule inet sso $SSO_CHAIN_IN ip saddr @${SSO_SET_BLOCK} drop" >/dev/null 2>&1 || return 1

  nft "add rule inet sso $SSO_CHAIN_OUT ip daddr @${SSO_SET_WHITE} accept" >/dev/null 2>&1 || return 1
  if [[ -f "$STATE_BTFLAG" ]]; then
    nft "add rule inet sso $SSO_CHAIN_OUT tcp dport { 6881-6889, 6969, 51413 } drop" >/dev/null 2>&1 || return 1
    nft "add rule inet sso $SSO_CHAIN_OUT udp dport { 6881-6889, 6969, 51413 } drop" >/dev/null 2>&1 || return 1
  fi
  nft "add rule inet sso $SSO_CHAIN_OUT ip daddr @${SSO_SET_BLOCK} drop" >/dev/null 2>&1 || return 1

  nft list table inet sso >/dev/null 2>&1 || {
    err "nftables apply did not create the expected SSO table."
    return 1
  }

  ok "Applied nftables backend (INPUT+OUTPUT)."
}

ipset_load_file() {
  local set_name="$1"
  local file="$2"
  local entry
  local restore_file

  restore_file="$(mktemp)" || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf 'add %s %s\n' "$set_name" "$entry" >> "$restore_file"
  done < "$file"

  if [[ -s "$restore_file" ]] && ! ipset restore < "$restore_file" >/dev/null 2>&1; then
    rm -f -- "$restore_file"
    return 1
  fi
  rm -f -- "$restore_file"
}

ipset_prepare_set() {
  local set_name="$1"
  if ipset list "$set_name" >/dev/null 2>&1; then
    ipset flush "$set_name" >/dev/null 2>&1
  else
    ipset create "$set_name" hash:net family inet maxelem 200000 >/dev/null 2>&1
  fi
}

iptables_prepare_chain() {
  local chain="$1"
  if iptables -S "$chain" >/dev/null 2>&1; then
    iptables -F "$chain" >/dev/null 2>&1
  else
    iptables -N "$chain" >/dev/null 2>&1
  fi
}

ipset_apply() {
  ensure_default_whitelist || return 1
  ensure_state_blocklist || return 1

  ipset_prepare_set sso_block_v4 || { err "Could not prepare block ipset."; return 1; }
  ipset_prepare_set sso_white_v4 || { err "Could not prepare whitelist ipset."; return 1; }

  ipset_load_file sso_block_v4 "$STATE_BLOCKLIST" || { err "ipset rejected one or more blocklist entries."; return 1; }
  ipset_load_file sso_white_v4 "$STATE_WHITELIST" || { err "ipset rejected one or more whitelist entries."; return 1; }

  iptables_prepare_chain SSO_IN || return 1
  iptables_prepare_chain SSO_OUT || return 1

  iptables -C INPUT -j SSO_IN >/dev/null 2>&1 || iptables -I INPUT 1 -j SSO_IN >/dev/null 2>&1 || return 1
  iptables -C OUTPUT -j SSO_OUT >/dev/null 2>&1 || iptables -I OUTPUT 1 -j SSO_OUT >/dev/null 2>&1 || return 1

  iptables -A SSO_IN -m set --match-set sso_white_v4 src -j RETURN >/dev/null 2>&1 || return 1
  if [[ -f "$STATE_BTFLAG" ]]; then
    iptables -A SSO_IN -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP >/dev/null 2>&1 || return 1
    iptables -A SSO_IN -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP >/dev/null 2>&1 || return 1
  fi
  iptables -A SSO_IN -m set --match-set sso_block_v4 src -j DROP >/dev/null 2>&1 || return 1
  iptables -A SSO_IN -j RETURN >/dev/null 2>&1 || return 1

  iptables -A SSO_OUT -m set --match-set sso_white_v4 dst -j RETURN >/dev/null 2>&1 || return 1
  if [[ -f "$STATE_BTFLAG" ]]; then
    iptables -A SSO_OUT -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP >/dev/null 2>&1 || return 1
    iptables -A SSO_OUT -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP >/dev/null 2>&1 || return 1
  fi
  iptables -A SSO_OUT -m set --match-set sso_block_v4 dst -j DROP >/dev/null 2>&1 || return 1
  iptables -A SSO_OUT -j RETURN >/dev/null 2>&1 || return 1

  ipset list sso_block_v4 >/dev/null 2>&1 || { err "ipset apply did not create the expected sets."; return 1; }
  iptables -S SSO_IN >/dev/null 2>&1 || { err "iptables apply did not create the expected chains."; return 1; }

  ok "Applied iptables+ipset backend (INPUT+OUTPUT)."
}

firewall_runtime_set_change() {
  local backend="$1"
  local list_kind="$2"
  local action="$3"
  local entry="$4"
  local set_name

  case "$list_kind" in
    block) set_name="$SSO_SET_BLOCK" ;;
    white) set_name="$SSO_SET_WHITE" ;;
    *) return 1 ;;
  esac

  case "$backend" in
    nft)
      if nft "get element inet sso $set_name { $entry }" >/dev/null 2>&1; then
        [[ "$action" == "add" ]] && return 0
        nft "delete element inet sso $set_name { $entry }" >/dev/null 2>&1
      else
        [[ "$action" == "remove" ]] && return 0
        nft "add element inet sso $set_name { $entry }" >/dev/null 2>&1
      fi
      ;;
    ipset)
      if ipset test "$set_name" "$entry" >/dev/null 2>&1; then
        [[ "$action" == "add" ]] && return 0
        ipset del "$set_name" "$entry" >/dev/null 2>&1
      else
        [[ "$action" == "remove" ]] && return 0
        ipset add "$set_name" "$entry" >/dev/null 2>&1
      fi
      ;;
    none) return 0 ;;
    *) return 1 ;;
  esac
}

firewall_list_change() {
  local list_kind="$1"
  local action="$2"
  local entry="$3"
  local file backend previous candidate

  validate_ipv4_or_cidr "$entry" || {
    err "Invalid IPv4 or CIDR: $entry"
    return 1
  }

  case "$list_kind" in
    block)
      ensure_state_blocklist || return 1
      file="$STATE_BLOCKLIST"
      ;;
    white)
      ensure_default_whitelist || return 1
      file="$STATE_WHITELIST"
      if [[ "$action" == "remove" && "$entry" == "10.235.0.0/19" ]]; then
        err "10.235.0.0/19 is the required default whitelist entry and cannot be removed here."
        return 1
      fi
      ;;
    *) return 1 ;;
  esac

  previous="$(mktemp)" || return 1
  candidate="$(mktemp)" || { rm -f -- "$previous"; return 1; }
  cp -a -- "$file" "$previous" || { rm -f -- "$previous" "$candidate"; return 1; }

  case "$action" in
    add)
      cat -- "$file" > "$candidate" || true
      printf '%s\n' "$entry" >> "$candidate"
      ;;
    remove)
      grep -vxF "$entry" "$file" > "$candidate" || true
      ;;
    *)
      rm -f -- "$previous" "$candidate"
      return 1
      ;;
  esac

  if ! normalize_iplist_source "$candidate" "$file" "$list_kind list"; then
    cp -a -- "$previous" "$file" 2>/dev/null || true
    rm -f -- "$previous" "$candidate"
    return 1
  fi

  if [[ "$list_kind" == "white" ]] && ! ensure_default_whitelist; then
    cp -a -- "$previous" "$file" 2>/dev/null || true
    rm -f -- "$previous" "$candidate"
    return 1
  fi

  backend="$(firewall_active_backend)"
  if [[ "$backend" != "none" ]]; then
    if ! firewall_runtime_set_change "$backend" "$list_kind" "$action" "$entry"; then
      cp -a -- "$previous" "$file" 2>/dev/null || true
      err "Runtime firewall update failed; the saved list was restored."
      rm -f -- "$previous" "$candidate"
      return 1
    fi
    ok "Saved and applied immediately using $backend."
  else
    ok "Saved. SSO firewall is not currently active, so no runtime update was needed."
  fi

  rm -f -- "$previous" "$candidate"
}

module_firewall_apply() {
  header
  section "Apply/refresh SSO firewall rules (INPUT+OUTPUT)"

  if ! ensure_default_whitelist || ! ensure_state_blocklist; then
    err "Firewall state validation failed. Nothing was applied."
    pause
    return 0
  fi

  local d backend
  d="$(backup_create "firewall:apply")"
  backend="$(detect_firewall_backend)"

  case "$backend" in
    nft)
      if ! run_step "Applying firewall rules (nftables)" nft_apply; then
        err "Firewall apply failed."
        pause
        return 0
      fi
      ;;
    ipset)
      if ! run_step "Applying firewall rules (iptables+ipset)" ipset_apply; then
        err "Firewall apply failed."
        pause
        return 0
      fi
      ;;
    *)
      if cmd_exists nft; then
        warn "nft exists but is not usable on this system."
      fi
      err "No supported firewall backend found (need nft OR iptables+ipset)."
      pause
      return 0
      ;;
  esac

  if ! firewall_persist_enable; then
    err "Firewall rules were applied, but persistence could not be enabled."
    pause
    return 0
  fi

  ok "Backup: $d"
  pause
}

module_firewall_disable() {
  header
  section "Disable SSO firewall rules"
  local d failed=0
  d="$(backup_create "firewall:disable")"

  firewall_persist_disable

  if cmd_exists nft && nft list table inet sso >/dev/null 2>&1; then
    info "Removing nftables table: inet sso"
    nft delete table inet sso >/dev/null 2>&1 || failed=1
    if nft list table inet sso >/dev/null 2>&1; then
      err "nftables table inet sso is still present."
      failed=1
    else
      ok "nftables table inet sso removed."
    fi
  fi

  if cmd_exists iptables; then
    iptables -D INPUT -j SSO_IN 2>/dev/null || true
    iptables -D OUTPUT -j SSO_OUT 2>/dev/null || true
    iptables -F SSO_IN 2>/dev/null || true
    iptables -F SSO_OUT 2>/dev/null || true
    iptables -X SSO_IN 2>/dev/null || true
    iptables -X SSO_OUT 2>/dev/null || true

    if iptables -S 2>/dev/null | grep -qE '(^-N SSO_IN|^-N SSO_OUT|SSO_IN|SSO_OUT)'; then
      warn "Some iptables references to SSO chains still exist."
      failed=1
    fi
  fi

  if cmd_exists ipset; then
    ipset destroy sso_block_v4 2>/dev/null || true
    ipset destroy sso_white_v4 2>/dev/null || true
  fi

  if [[ "$failed" -eq 0 ]]; then
    ok "SSO firewall disabled. (Backup: $d)"
  else
    warn "Firewall disable finished with warnings; inspect current firewall state. (Backup: $d)"
  fi
  pause
}

module_firewall_blacklist_menu() {
  ensure_state_blocklist || return 0
  while true; do
    header
    section "Blacklist manager"
    echo "Blacklist file: $STATE_BLOCKLIST"
    echo "1) Show blacklist"
    echo "2) Add IP/CIDR"
    echo "3) Remove IP/CIDR"
    echo "0) Back"
    local choice ip
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header
        section "Blacklist"
        if [[ ! -s "$STATE_BLOCKLIST" ]]; then
          info "Blacklist is empty."
        else
          nl -w2 -s') ' "$STATE_BLOCKLIST" || true
        fi
        pause
        ;;
      2)
        read_input "Enter IP/CIDR to blacklist: " ip || { warn "No input received."; pause; continue; }
        ip="${ip//[[:space:]]/}"
        if firewall_list_change block add "$ip"; then
          ok "Blacklist updated: $STATE_BLOCKLIST"
        fi
        pause
        ;;
      3)
        read_input "Enter IP/CIDR to remove: " ip || { warn "No input received."; pause; continue; }
        ip="${ip//[[:space:]]/}"
        if firewall_list_change block remove "$ip"; then
          ok "Blacklist updated: $STATE_BLOCKLIST"
        fi
        pause
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

module_firewall_whitelist_menu() {
  ensure_default_whitelist || return 0
  while true; do
    header
    section "Whitelist manager"
    echo "Whitelist file: $STATE_WHITELIST"
    echo "1) Show whitelist"
    echo "2) Add IP/CIDR"
    echo "3) Remove IP/CIDR"
    echo "0) Back"
    local choice ip
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header
        section "Whitelist"
        if [[ ! -s "$STATE_WHITELIST" ]]; then
          info "Whitelist is empty."
        else
          nl -w2 -s') ' "$STATE_WHITELIST" || true
        fi
        pause
        ;;
      2)
        read_input "Enter IP/CIDR to whitelist: " ip || { warn "No input received."; pause; continue; }
        ip="${ip//[[:space:]]/}"
        if firewall_list_change white add "$ip"; then
          ok "Whitelist updated: $STATE_WHITELIST"
        fi
        pause
        ;;
      3)
        read_input "Enter IP/CIDR to remove: " ip || { warn "No input received."; pause; continue; }
        ip="${ip//[[:space:]]/}"
        if firewall_list_change white remove "$ip"; then
          ok "Whitelist updated: $STATE_WHITELIST"
        fi
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
  local available_backend active_backend
  available_backend="$(detect_firewall_backend)"
  active_backend="$(firewall_active_backend)"

  info "Available backend: $available_backend"
  if [[ "$active_backend" == "none" ]]; then
    info "SSO firewall: not active"
  else
    ok "SSO firewall: ACTIVE ($active_backend)"
  fi

  if ! ensure_default_whitelist || ! ensure_state_blocklist; then
    err "Firewall state contains invalid data."
    pause
    return 0
  fi

  info "Blocklist entries: $(wc -l < "$STATE_BLOCKLIST" | tr -d " ")"
  info "Whitelist entries: $(wc -l < "$STATE_WHITELIST" | tr -d " ")"
  info "Common BitTorrent-port block: $( [[ -f "$STATE_BTFLAG" ]] && echo "ENABLED" || echo "disabled" )"
  echo ""

  if [[ "$active_backend" == "nft" ]]; then
    nft list table inet sso 2>/dev/null | sed -n '1,120p' || true
  elif [[ "$active_backend" == "ipset" ]]; then
    ipset list sso_block_v4 2>/dev/null | sed -n '1,40p' || true
    iptables -S SSO_IN 2>/dev/null || true
    iptables -S SSO_OUT 2>/dev/null || true
  fi
  pause
}

module_firewall_bittorrent_menu() {
  header
  section "Common BitTorrent ports (best effort)"
  ensure_dirs "$STATE_DIR"
  warn "This blocks common BitTorrent-related ports only; it is not complete protocol detection."

  if [[ -f "$STATE_BTFLAG" ]]; then
    info "Common-port blocking is ENABLED."
    echo "1) Disable common-port blocking"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        rm -f "$STATE_BTFLAG" 2>/dev/null || true
        ok "Common-port blocking disabled in saved SSO state."
        if [[ "$(firewall_active_backend)" != "none" ]]; then
          info "SSO firewall is active; choose Apply/refresh to update the active rules."
        fi
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  else
    info "Common-port blocking is disabled."
    echo "1) Enable common-port blocking"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        : > "$STATE_BTFLAG"
        ok "Common-port blocking enabled in saved SSO state."
        if [[ "$(firewall_active_backend)" != "none" ]]; then
          info "SSO firewall is active; choose Apply/refresh to update the active rules."
        else
          info "Choose Apply/refresh when you want to activate SSO firewall rules."
        fi
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  fi
  pause
}
