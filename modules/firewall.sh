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

firewall_backend_label() {
  case "${1:-none}" in
    nft) printf '%s\n' "nftables" ;;
    ipset) printf '%s\n' "iptables+ipset" ;;
    none) printf '%s\n' "inactive" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

firewall_parse_entries() {
  local raw="${1:-}"
  local -n __valid="$2"
  local -n __invalid="$3"
  local -n __duplicate_count="$4"
  local normalized token
  local -a tokens=()
  local -A seen=()

  __valid=()
  __invalid=()
  __duplicate_count=0
  normalized="${raw//,/ }"
  read -r -a tokens <<<"$normalized"

  for token in "${tokens[@]}"; do
    [[ -n "$token" ]] || continue
    if [[ -n "${seen[$token]+x}" ]]; then
      __duplicate_count=$((__duplicate_count + 1))
      continue
    fi
    seen["$token"]=1

    if validate_ipv4_or_cidr "$token"; then
      __valid+=("$token")
    else
      __invalid+=("$token")
    fi
  done
}

firewall_runtime_mutate_entry() {
  local backend="$1"
  local set_name="$2"
  local action="$3"
  local entry="$4"

  case "$backend:$action" in
    nft:add) nft "add element inet sso $set_name { $entry }" >/dev/null 2>&1 ;;
    nft:remove) nft "delete element inet sso $set_name { $entry }" >/dev/null 2>&1 ;;
    ipset:add) ipset add "$set_name" "$entry" >/dev/null 2>&1 ;;
    ipset:remove) ipset del "$set_name" "$entry" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

firewall_runtime_set_change_batch() {
  local backend="$1"
  local list_kind="$2"
  local action="$3"
  shift 3
  local -a changed=("$@") applied=()
  local set_name entry elements opposite i rollback_failed=0

  case "$list_kind" in
    block) set_name="$SSO_SET_BLOCK" ;;
    white) set_name="$SSO_SET_WHITE" ;;
    *) return 1 ;;
  esac

  [[ "$action" == "add" || "$action" == "remove" ]] || return 1
  [[ "$backend" == "nft" || "$backend" == "ipset" ]] || return 1
  ((${#changed[@]} > 0)) || return 0

  # The caller computes changes from validated persisted state. Do not hide
  # runtime drift with an existence probe: an unexpected add/delete failure is
  # treated as a live-update failure so persisted state can be restored.
  if [[ "$backend" == "nft" ]]; then
    elements="$(IFS=,; printf '%s' "${changed[*]}")"
    case "$action" in
      add) nft "add element inet sso $set_name { $elements }" >/dev/null 2>&1 ;;
      remove) nft "delete element inet sso $set_name { $elements }" >/dev/null 2>&1 ;;
    esac
    return $?
  fi

  opposite="remove"
  [[ "$action" == "remove" ]] && opposite="add"
  for entry in "${changed[@]}"; do
    if firewall_runtime_mutate_entry "$backend" "$set_name" "$action" "$entry"; then
      applied+=("$entry")
      continue
    fi

    for ((i=${#applied[@]} - 1; i>=0; i--)); do
      firewall_runtime_mutate_entry "$backend" "$set_name" "$opposite" "${applied[$i]}" || rollback_failed=1
    done
    [[ "$rollback_failed" -eq 0 ]] && return 1
    return 2
  done
  return 0
}

firewall_runtime_set_change() {
  firewall_runtime_set_change_batch "$1" "$2" "$3" "$4"
}

firewall_read_entries() {
  local purpose="$1"
  local out_name="$2"
  local backend label

  info "Enter one or more IPv4 addresses/CIDRs to $purpose."
  muted "Examples: 203.0.113.10  |  203.0.113.0/24"
  muted "Multiple: 203.0.113.10, 198.51.100.0/24 192.0.2.5 (comma and/or spaces)"

  backend="$(firewall_active_backend)"
  if [[ "$backend" == "none" ]]; then
    info "Accepted changes are saved only; the inactive SSO firewall will not be enabled."
  else
    label="$(firewall_backend_label "$backend")"
    info "Accepted changes are saved and applied immediately to the active $label backend."
  fi

  read_input "Entries: " "$out_name"
}

firewall_report_batch_summary() {
  local action="$1"
  local requested="$2"
  local changed="$3"
  local unchanged="$4"
  local duplicates="$5"
  local backend="$6"
  local label

  info "Requested: $requested"
  if [[ "$action" == "add" ]]; then
    ok "Added: $changed"
    info "Already present: $unchanged"
  else
    ok "Removed: $changed"
    info "Not present: $unchanged"
  fi
  ((duplicates > 0)) && info "Duplicates ignored: $duplicates"

  if [[ "$backend" == "none" ]]; then
    info "Applied now: no (SSO firewall inactive)"
  else
    label="$(firewall_backend_label "$backend")"
    if ((changed > 0)); then
      ok "Applied now: yes ($label)"
    else
      info "Applied now: no changes needed ($label active)"
    fi
  fi
}

firewall_list_change() {
  local list_kind="$1"
  local action="$2"
  local raw="${3:-}"
  local file backend previous candidate entry runtime_rc=0
  local duplicates=0 requested=0 changed_count=0 unchanged_count=0
  local -a entries=() invalid=() effective=()

  firewall_parse_entries "$raw" entries invalid duplicates
  if ((${#invalid[@]} > 0)); then
    err "Invalid IPv4/CIDR entries: ${invalid[*]}"
    info "Valid examples: 203.0.113.10 or 203.0.113.0/24; separate multiple entries with commas and/or spaces."
    return 1
  fi
  if ((${#entries[@]} == 0)); then
    err "No IPv4/CIDR entries were provided."
    info "Enter at least one value such as 203.0.113.10 or 203.0.113.0/24."
    return 1
  fi

  case "$list_kind" in
    block)
      ensure_state_blocklist || return 1
      file="$STATE_BLOCKLIST"
      ;;
    white)
      ensure_default_whitelist || return 1
      file="$STATE_WHITELIST"
      if [[ "$action" == "remove" ]]; then
        for entry in "${entries[@]}"; do
          if [[ "$entry" == "10.235.0.0/19" ]]; then
            err "Batch rejected: 10.235.0.0/19 is the required default whitelist entry and cannot be removed."
            info "No whitelist entries from this batch were changed."
            return 1
          fi
        done
      fi
      ;;
    *) return 1 ;;
  esac

  requested=${#entries[@]}
  case "$action" in
    add)
      for entry in "${entries[@]}"; do
        if grep -qxF -- "$entry" "$file" 2>/dev/null; then
          unchanged_count=$((unchanged_count + 1))
        else
          effective+=("$entry")
        fi
      done
      ;;
    remove)
      for entry in "${entries[@]}"; do
        if grep -qxF -- "$entry" "$file" 2>/dev/null; then
          effective+=("$entry")
        else
          unchanged_count=$((unchanged_count + 1))
        fi
      done
      ;;
    *) return 1 ;;
  esac
  changed_count=${#effective[@]}

  backend="$(firewall_active_backend)"
  if ((changed_count == 0)); then
    firewall_report_batch_summary "$action" "$requested" 0 "$unchanged_count" "$duplicates" "$backend"
    return 0
  fi

  previous="$(mktemp)" || return 1
  candidate="$(mktemp)" || { rm -f -- "$previous"; return 1; }
  cp -a -- "$file" "$previous" || { rm -f -- "$previous" "$candidate"; return 1; }
  cp -a -- "$file" "$candidate" || { rm -f -- "$previous" "$candidate"; return 1; }

  case "$action" in
    add)
      printf '%s\n' "${effective[@]}" >> "$candidate"
      ;;
    remove)
      for entry in "${effective[@]}"; do
        grep -vxF -- "$entry" "$candidate" > "${candidate}.next" || true
        mv -- "${candidate}.next" "$candidate" || {
          rm -f -- "$previous" "$candidate" "${candidate}.next"
          return 1
        }
      done
      ;;
  esac

  if ! normalize_iplist_source "$candidate" "$file" "$list_kind list"; then
    cp -a -- "$previous" "$file" 2>/dev/null || true
    rm -f -- "$previous" "$candidate" "${candidate}.next"
    return 1
  fi

  if [[ "$list_kind" == "white" ]] && ! ensure_default_whitelist; then
    cp -a -- "$previous" "$file" 2>/dev/null || true
    rm -f -- "$previous" "$candidate" "${candidate}.next"
    return 1
  fi

  if [[ "$backend" != "none" ]]; then
    firewall_runtime_set_change_batch "$backend" "$list_kind" "$action" "${effective[@]}" || runtime_rc=$?
    if [[ "$runtime_rc" -ne 0 ]]; then
      cp -a -- "$previous" "$file" 2>/dev/null || true
      if [[ "$runtime_rc" -eq 2 ]]; then
        err "Runtime firewall update failed and its compensating rollback also failed."
        err "The saved list was restored, but active $backend state may need explicit Apply/refresh after the backend issue is fixed."
      else
        err "Runtime firewall update failed; the saved list was restored and the batch was not accepted."
      fi
      rm -f -- "$previous" "$candidate" "${candidate}.next"
      return 1
    fi
  fi

  ok "Saved state: updated"
  firewall_report_batch_summary "$action" "$requested" "$changed_count" "$unchanged_count" "$duplicates" "$backend"
  rm -f -- "$previous" "$candidate" "${candidate}.next"
}

firewall_apply_active_backend() {
  case "$1" in
    nft) nft_apply ;;
    ipset) ipset_apply ;;
    *) return 1 ;;
  esac
}

firewall_set_bittorrent_state() {
  local desired="$1"
  local backend previous=0 rollback_failed=0

  [[ -f "$STATE_BTFLAG" ]] && previous=1
  if [[ "$desired" == "enabled" ]]; then
    : > "$STATE_BTFLAG" || return 1
  elif [[ "$desired" == "disabled" ]]; then
    rm -f -- "$STATE_BTFLAG" || return 1
  else
    return 1
  fi

  backend="$(firewall_active_backend)"
  if [[ "$backend" == "none" ]]; then
    ok "Common-port blocking $desired in saved SSO state."
    info "SSO firewall is inactive; it was not enabled. This setting will take effect when SSO firewall rules are activated."
    return 0
  fi

  if firewall_apply_active_backend "$backend"; then
    ok "Common-port blocking $desired, saved and applied immediately using $(firewall_backend_label "$backend")."
    return 0
  fi

  if [[ "$previous" -eq 1 ]]; then
    : > "$STATE_BTFLAG" || rollback_failed=1
  else
    rm -f -- "$STATE_BTFLAG" || rollback_failed=1
  fi

  if [[ "$rollback_failed" -ne 0 ]]; then
    err "Live firewall update failed, and the previous saved toggle could not be restored."
    err "Inspect $STATE_BTFLAG and active rules before retrying."
    return 1
  fi

  if firewall_apply_active_backend "$backend"; then
    err "Live firewall update failed; the previous saved toggle and active rules were restored."
  else
    err "Live firewall update failed; the previous saved toggle was restored, but active firewall rollback could not be verified."
    err "Fix the backend problem, then use Apply/refresh SSO firewall rules to reconcile active state."
  fi
  return 1
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
    muted "Blacklist file: $STATE_BLOCKLIST"
    menu_item "1) Show blacklist"
    menu_item "2) Add one or more IPv4/CIDRs"
    menu_item "3) Remove one or more IPv4/CIDRs"
    menu_secondary "0) Back"
    local choice entries_raw
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
        if ! firewall_read_entries "add to the blacklist" entries_raw; then
          warn "No input received; blacklist was not changed."
          pause
          continue
        fi
        firewall_list_change block add "$entries_raw" || true
        pause
        ;;
      3)
        if ! firewall_read_entries "remove from the blacklist" entries_raw; then
          warn "No input received; blacklist was not changed."
          pause
          continue
        fi
        firewall_list_change block remove "$entries_raw" || true
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
    muted "Whitelist file: $STATE_WHITELIST"
    menu_item "1) Show whitelist"
    menu_item "2) Add one or more IPv4/CIDRs"
    menu_warn "3) Remove one or more IPv4/CIDRs"
    menu_secondary "0) Back"
    local choice entries_raw
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
        if ! firewall_read_entries "add to the whitelist" entries_raw; then
          warn "No input received; whitelist was not changed."
          pause
          continue
        fi
        firewall_list_change white add "$entries_raw" || true
        pause
        ;;
      3)
        warn "The required default whitelist entry 10.235.0.0/19 cannot be removed."
        if ! firewall_read_entries "remove from the whitelist" entries_raw; then
          warn "No input received; whitelist was not changed."
          pause
          continue
        fi
        firewall_list_change white remove "$entries_raw" || true
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
    status_inactive "SSO firewall: not active"
  else
    status_active "SSO firewall: ACTIVE ($(firewall_backend_label "$active_backend"))"
  fi

  if ! ensure_default_whitelist || ! ensure_state_blocklist; then
    err "Firewall state contains invalid data."
    pause
    return 0
  fi

  info "Blocklist entries: $(wc -l < "$STATE_BLOCKLIST" | tr -d " ")"
  info "Whitelist entries: $(wc -l < "$STATE_WHITELIST" | tr -d " ")"
  if [[ -f "$STATE_BTFLAG" ]]; then
    status_active "Common BitTorrent-port block: ENABLED"
  else
    status_inactive "Common BitTorrent-port block: disabled"
  fi
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
    status_active "Common-port blocking is ENABLED."
    menu_warn "1) Disable common-port blocking"
    menu_secondary "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1) firewall_set_bittorrent_state disabled || true ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  else
    status_inactive "Common-port blocking is disabled."
    menu_warn "1) Enable common-port blocking"
    menu_secondary "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1) firewall_set_bittorrent_state enabled || true ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  fi
  pause
}
