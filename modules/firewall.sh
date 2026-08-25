#!/usr/bin/env bash
set -Eeuo pipefail

SSO_SET_BLOCK="sso_block_v4"
SSO_SET_WHITE="sso_white_v4"
SSO_CHAIN_IN="sso_in"
SSO_CHAIN_OUT="sso_out"
SSO_NFT_TABLE_PRIMARY="sso"
SSO_NFT_TABLE_SECONDARY="sso_next"
SSO_NFT_CHUNK_SIZE="${SSO_NFT_CHUNK_SIZE:-500}"
SSO_REQUIRED_WHITELIST="10.235.0.0/19"

STATE_BLOCKLIST="$STATE_DIR/blocklist-ip.ipv4"
STATE_WHITELIST="$STATE_DIR/whitelist-ip.ipv4"
STATE_BTFLAG="$STATE_DIR/block-bittorrent.enabled"
FIREWALL_LOCK_FILE="${FIREWALL_LOCK_FILE:-$STATE_DIR/firewall.lock}"
FIREWALL_LOCK_FD="${FIREWALL_LOCK_FD:-}"

canonicalize_ipv4_or_cidr() {
  local value="$1"
  local ip="$value"
  local prefix=""

  if [[ "$value" == */* ]]; then
    ip="${value%/*}"
    prefix="${value#*/}"
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  fi

  local a b c d extra
  IFS='.' read -r a b c d extra <<< "$ip"
  [[ -z "${extra:-}" ]] || return 1

  local octet raw
  local -a raw_octets=("${a:-}" "${b:-}" "${c:-}" "${d:-}")
  local -a octets=()
  for raw in "${raw_octets[@]}"; do
    [[ "$raw" =~ ^[0-9]{1,3}$ ]] || return 1
    octet=$((10#$raw))
    (( octet >= 0 && octet <= 255 )) || return 1
    octets+=("$octet")
  done

  if [[ -z "$prefix" ]]; then
    printf '%d.%d.%d.%d\n' "${octets[0]}" "${octets[1]}" "${octets[2]}" "${octets[3]}"
    return 0
  fi

  local prefix_num=$((10#$prefix))
  (( prefix_num >= 0 && prefix_num <= 32 )) || return 1

  local ip_num=$(( (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3] ))
  local mask_num=0
  if (( prefix_num > 0 )); then
    mask_num=$(( (0xFFFFFFFF << (32 - prefix_num)) & 0xFFFFFFFF ))
  fi
  local net=$(( ip_num & mask_num ))

  if (( prefix_num == 32 )); then
    printf '%d.%d.%d.%d\n' \
      $(( (net >> 24) & 255 )) \
      $(( (net >> 16) & 255 )) \
      $(( (net >> 8) & 255 )) \
      $(( net & 255 ))
  else
    printf '%d.%d.%d.%d/%d\n' \
      $(( (net >> 24) & 255 )) \
      $(( (net >> 16) & 255 )) \
      $(( (net >> 8) & 255 )) \
      $(( net & 255 )) \
      "$prefix_num"
  fi
}

ipv4_cidr_to_range() {
  local value="$1"
  local ip="$value" prefix=32
  if [[ "$value" == */* ]]; then
    ip="${value%/*}"
    prefix="${value#*/}"
  fi

  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  local start=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
  local size=$(( 1 << (32 - prefix) ))
  local end=$(( start + size - 1 ))
  printf '%u %u\n' "$start" "$end"
}

collapse_ipv4_ranges() {
  LC_ALL=C sort -n -k1,1 -k2,2r | awk '
    function emit_range(s, e,    align,tmp,remaining,block,prefix,x,a,b,c,d,r,ip) {
      while (s <= e) {
        if (s == 0) {
          align = 4294967296
        } else {
          align = 1
          tmp = s
          while ((tmp % 2) == 0 && align < 4294967296) {
            align *= 2
            tmp /= 2
          }
        }

        remaining = e - s + 1
        block = 1
        while ((block * 2) <= remaining) block *= 2
        if (align < block) block = align

        prefix = 32
        x = block
        while (x > 1) {
          prefix--
          x /= 2
        }

        a = int(s / 16777216)
        r = s - (a * 16777216)
        b = int(r / 65536)
        r -= b * 65536
        c = int(r / 256)
        d = r - (c * 256)
        ip = a "." b "." c "." d
        if (prefix == 32) print ip
        else print ip "/" prefix

        s += block
      }
    }

    NR == 1 {
      start = $1
      end = $2
      next
    }
    $1 <= (end + 1) {
      if ($2 > end) end = $2
      next
    }
    {
      emit_range(start, end)
      start = $1
      end = $2
    }
    END {
      if (NR > 0) emit_range(start, end)
    }
  '
}

sanitize_iplist() {
  local ranges
  ranges="$(mktemp)" || return 1

  if ! awk '
    function fail(msg) {
      printf "Invalid IPv4/CIDR at line %d: %s\n", NR, msg > "/dev/stderr"
      bad = 1
      exit 2
    }

    {
      line = $0
      sub(/\r$/, "", line)
      sub(/#.*/, "", line)
      sub(/;.*/, "", line)
      gsub(/[[:space:]]/, "", line)
      if (line == "") next

      slash_count = split(line, parts, "/")
      if (slash_count > 2) fail(line)
      ip = parts[1]
      prefix = 32
      if (slash_count == 2) {
        if (parts[2] !~ /^[0-9]{1,2}$/) fail(line)
        prefix = parts[2] + 0
        if (prefix < 0 || prefix > 32) fail(line)
      }

      n = split(ip, octets, ".")
      if (n != 4) fail(line)
      for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]{1,3}$/) fail(line)
        value[i] = octets[i] + 0
        if (value[i] < 0 || value[i] > 255) fail(line)
      }

      ipnum = value[1] * 16777216 + value[2] * 65536 + value[3] * 256 + value[4]
      size = 2 ^ (32 - prefix)
      start = int(ipnum / size) * size
      end = start + size - 1
      printf "%.0f %.0f\n", start, end
    }
  ' > "$ranges"; then
    rm -f "$ranges"
    return 1
  fi

  collapse_ipv4_ranges < "$ranges"
  local rc=$?
  rm -f "$ranges"
  return "$rc"
}

firewall_lock_acquire() {
  if [[ -n "${FIREWALL_LOCK_FD:-}" ]]; then
    return 0
  fi
  cmd_exists flock || {
    err "flock is required for safe firewall state updates (package: util-linux)."
    return 1
  }
  ensure_dirs "$STATE_DIR"

  local fd
  exec {fd}>"$FIREWALL_LOCK_FILE" || {
    err "Could not open firewall lock: $FIREWALL_LOCK_FILE"
    return 1
  }
  if ! flock -x "$fd"; then
    eval "exec ${fd}>&-"
    err "Could not acquire firewall state lock."
    return 1
  fi
  FIREWALL_LOCK_FD="$fd"
}

firewall_lock_release() {
  [[ -n "${FIREWALL_LOCK_FD:-}" ]] || return 0
  local fd="$FIREWALL_LOCK_FD"
  flock -u "$fd" 2>/dev/null || true
  eval "exec ${fd}>&-"
  FIREWALL_LOCK_FD=""
}

firewall_with_lock() {
  if [[ -n "${FIREWALL_LOCK_FD:-}" ]]; then
    "$@"
    return $?
  fi

  firewall_lock_acquire || return 1
  local rc=0
  if "$@"; then
    rc=0
  else
    rc=$?
  fi
  firewall_lock_release
  return "$rc"
}

normalize_iplist_file() {
  local source="$1"
  local target="$2"
  local target_dir
  target_dir="$(dirname "$target")"
  ensure_dirs "$target_dir"

  local tmp
  tmp="$(mktemp "$target_dir/.sso-iplist.XXXXXX")" || return 1
  if ! sanitize_iplist < "$source" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$target"
}

_ensure_default_whitelist_core() {
  ensure_dirs "$STATE_DIR"

  local raw normalized
  raw="$(mktemp "$STATE_DIR/.whitelist.raw.XXXXXX")" || return 1
  normalized="$(mktemp "$STATE_DIR/.whitelist.normalized.XXXXXX")" || {
    rm -f "$raw"
    return 1
  }

  if [[ -f "$STATE_WHITELIST" ]]; then
    cat "$STATE_WHITELIST" > "$raw" || {
      rm -f "$raw" "$normalized"
      return 1
    }
  elif [[ -f "$ASSETS_DIR/whitelist-default.ipv4" ]]; then
    cat "$ASSETS_DIR/whitelist-default.ipv4" > "$raw" || {
      rm -f "$raw" "$normalized"
      return 1
    }
  fi
  printf '%s\n' "$SSO_REQUIRED_WHITELIST" >> "$raw"

  if ! sanitize_iplist < "$raw" > "$normalized"; then
    rm -f "$raw" "$normalized"
    return 1
  fi
  chmod 0644 "$normalized" || {
    rm -f "$raw" "$normalized"
    return 1
  }
  mv -f "$normalized" "$STATE_WHITELIST" || {
    rm -f "$raw" "$normalized"
    return 1
  }
  rm -f "$raw"
}

ensure_default_whitelist() {
  firewall_with_lock _ensure_default_whitelist_core
}

_ensure_state_blocklist_core() {
  ensure_dirs "$STATE_DIR"
  local raw normalized
  raw="$(mktemp "$STATE_DIR/.blocklist.raw.XXXXXX")" || return 1
  normalized="$(mktemp "$STATE_DIR/.blocklist.normalized.XXXXXX")" || {
    rm -f "$raw"
    return 1
  }

  if [[ -f "$STATE_BLOCKLIST" ]]; then
    cat "$STATE_BLOCKLIST" > "$raw" || {
      rm -f "$raw" "$normalized"
      return 1
    }
  fi

  if ! sanitize_iplist < "$raw" > "$normalized"; then
    rm -f "$raw" "$normalized"
    return 1
  fi
  chmod 0644 "$normalized" || {
    rm -f "$raw" "$normalized"
    return 1
  }
  mv -f "$normalized" "$STATE_BLOCKLIST" || {
    rm -f "$raw" "$normalized"
    return 1
  }
  rm -f "$raw"
}

ensure_state_blocklist() {
  firewall_with_lock _ensure_state_blocklist_core
}

nft_table_has_chain() {
  local table="$1" chain="$2"
  nft list chain inet "$table" "$chain" >/dev/null 2>&1
}

nft_table_is_active() {
  local table="$1"
  local in out
  in="$(nft list chain inet "$table" "$SSO_CHAIN_IN" 2>/dev/null)" || return 1
  out="$(nft list chain inet "$table" "$SSO_CHAIN_OUT" 2>/dev/null)" || return 1
  grep -qE 'hook[[:space:]]+input' <<< "$in" || return 1
  grep -qE 'hook[[:space:]]+output' <<< "$out" || return 1
}

nft_table_has_any_sso_chain() {
  local table="$1"
  nft_table_has_chain "$table" "$SSO_CHAIN_IN" || nft_table_has_chain "$table" "$SSO_CHAIN_OUT"
}

nft_active_table() {
  local primary=0 secondary=0
  nft_table_is_active "$SSO_NFT_TABLE_PRIMARY" && primary=1
  nft_table_is_active "$SSO_NFT_TABLE_SECONDARY" && secondary=1

  if [[ "$primary" == "1" && "$secondary" == "1" ]]; then
    err "Both SSO nftables tables appear active; refusing ambiguous mutation."
    return 2
  fi
  if [[ "$primary" == "1" ]]; then
    printf '%s\n' "$SSO_NFT_TABLE_PRIMARY"
  elif [[ "$secondary" == "1" ]]; then
    printf '%s\n' "$SSO_NFT_TABLE_SECONDARY"
  fi
}

firewall_get_active_backends() {
  local -n _out="$1"
  _out=()

  if cmd_exists nft; then
    local nft_table="" nft_rc=0
    if nft_table="$(nft_active_table)"; then
      [[ -n "$nft_table" ]] && _out+=("nft")
    else
      nft_rc=$?
      if [[ "$nft_rc" -eq 2 ]]; then
        return 1
      fi
    fi
  fi

  if cmd_exists iptables && cmd_exists ipset \
    && iptables -S SSO_IN >/dev/null 2>&1 \
    && iptables -S SSO_OUT >/dev/null 2>&1 \
    && ipset list sso_block_v4 >/dev/null 2>&1 \
    && ipset list sso_white_v4 >/dev/null 2>&1; then
    _out+=("ipset")
  fi
}

firewall_active_backends() {
  local -a active=()
  firewall_get_active_backends active || return 1
  printf '%s\n' "${active[@]}"
}

detect_firewall_backend() {
  if cmd_exists nft; then
    if nft list ruleset >/dev/null 2>&1; then
      echo "nft"
      return 0
    fi
    echo "nft-unusable" >&2
  fi

  if cmd_exists iptables && cmd_exists iptables-restore && cmd_exists ipset; then
    echo "ipset"
    return 0
  fi

  echo "none"
}

firewall_persist_enable() {
  ensure_dirs "$STATE_DIR" /usr/local/sbin /etc/systemd/system
  printf '%s\n' "$SSO_DIR" > "$STATE_DIR/install_dir" || {
    err "Could not persist the SSO install directory."
    return 1
  }

  if ! cat > /usr/local/sbin/sso-firewall-restore <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="/etc/sso"
INSTALL_DIR="$(cat "$STATE_DIR/install_dir" 2>/dev/null || echo "/root/simple-server-optimizer")"
SSO_DIR="$INSTALL_DIR"
MODULES_DIR="$SSO_DIR/modules"
ASSETS_DIR="$SSO_DIR/assets"
source "$MODULES_DIR/utils.sh"
source "$MODULES_DIR/firewall.sh"

backend="$(detect_firewall_backend)"
case "$backend" in
  nft) nft_apply ;;
  ipset) ipset_apply ;;
  *) echo "No supported firewall backend." >&2; exit 1 ;;
esac
EOS
  then
    err "Could not write firewall restore helper."
    return 1
  fi
  chmod +x /usr/local/sbin/sso-firewall-restore || return 1

  if ! cat > /etc/systemd/system/sso-firewall.service <<'EOF'
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
  then
    err "Could not write sso-firewall.service."
    return 1
  fi

  run_step "Reloading systemd units" systemctl daemon-reload || return 1
  run_step "Enabling firewall persistence" systemctl enable sso-firewall.service || return 1
}

firewall_persist_disable() {
  info "Disabling firewall persistence"
  systemd_disable_now_safe sso-firewall.service
  rm -f /etc/systemd/system/sso-firewall.service /usr/local/sbin/sso-firewall-restore 2>/dev/null || true
  if ! run_step "Reloading systemd units" systemctl daemon-reload; then
    warn "systemd daemon-reload failed."
    return 1
  fi
  ok "Firewall persistence disabled."
}

nft_choose_staging_table() {
  local active="${1:-}"
  if [[ "$active" == "$SSO_NFT_TABLE_PRIMARY" ]]; then
    printf '%s\n' "$SSO_NFT_TABLE_SECONDARY"
  else
    printf '%s\n' "$SSO_NFT_TABLE_PRIMARY"
  fi
}

nft_remove_staging_table_if_safe() {
  local table="$1"
  if ! nft list table inet "$table" >/dev/null 2>&1; then
    return 0
  fi
  if nft_table_has_any_sso_chain "$table"; then
    err "Refusing to delete nft table '$table' because it contains SSO chains and is not a clean staging table."
    return 1
  fi
  nft delete table inet "$table"
}

nft_create_staging_table() {
  local table="$1"
  nft_remove_staging_table_if_safe "$table" || return 1

  local file log
  file="$(mktemp)" || return 1
  log="$(mktemp)" || { rm -f "$file"; return 1; }
  {
    printf 'add table inet %s\n' "$table"
    printf 'add set inet %s %s { type ipv4_addr; flags interval; auto-merge; }\n' "$table" "$SSO_SET_BLOCK"
    printf 'add set inet %s %s { type ipv4_addr; flags interval; auto-merge; }\n' "$table" "$SSO_SET_WHITE"
  } > "$file"

  if ! nft -c -f "$file" >"$log" 2>&1 || ! nft -f "$file" >"$log" 2>&1; then
    err "Could not create SSO nftables staging table '$table'."
    sed 's/^/    /' "$log" >&2 || true
    rm -f "$file" "$log"
    return 1
  fi
  rm -f "$file" "$log"
}

nft_apply_chunk_file() {
  local file="$1"
  local log
  log="$(mktemp)" || return 1
  if ! nft -c -f "$file" >"$log" 2>&1; then
    err "nftables validation rejected a staged list batch."
    sed 's/^/    /' "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  if ! nft -f "$file" >"$log" 2>&1; then
    err "nftables failed to commit a staged list batch."
    sed 's/^/    /' "$log" >&2 || true
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

nft_populate_set_batched() {
  local table="$1" set_name="$2" source="$3"
  [[ "$SSO_NFT_CHUNK_SIZE" =~ ^[0-9]+$ ]] && (( SSO_NFT_CHUNK_SIZE >= 1 )) || {
    err "Invalid SSO_NFT_CHUNK_SIZE: $SSO_NFT_CHUNK_SIZE"
    return 1
  }

  local batch count=0 ip total=0 batches=0
  batch="$(mktemp)" || return 1
  : > "$batch"

  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if (( count == 0 )); then
      printf 'add element inet %s %s { ' "$table" "$set_name" > "$batch"
    else
      printf ', ' >> "$batch"
    fi
    printf '%s' "$ip" >> "$batch"
    count=$((count + 1))
    total=$((total + 1))

    if (( count >= SSO_NFT_CHUNK_SIZE )); then
      printf ' }\n' >> "$batch"
      if ! nft_apply_chunk_file "$batch"; then
        rm -f "$batch"
        return 1
      fi
      : > "$batch"
      count=0
      batches=$((batches + 1))
    fi
  done < "$source"

  if (( count > 0 )); then
    printf ' }\n' >> "$batch"
    if ! nft_apply_chunk_file "$batch"; then
      rm -f "$batch"
      return 1
    fi
    batches=$((batches + 1))
  fi
  rm -f "$batch"
  info "Staged $total entries into $table/$set_name using $batches batch transaction(s)."
}

nft_build_activation_file() {
  local target="$1" old="$2" file="$3"
  {
    printf 'add chain inet %s %s { type filter hook input priority 0; policy accept; }\n' "$target" "$SSO_CHAIN_IN"
    printf 'add chain inet %s %s { type filter hook output priority 0; policy accept; }\n' "$target" "$SSO_CHAIN_OUT"
    printf 'add rule inet %s %s ip saddr @%s accept\n' "$target" "$SSO_CHAIN_IN" "$SSO_SET_WHITE"
    if [[ -f "$STATE_BTFLAG" ]]; then
      printf 'add rule inet %s %s tcp dport { 6881-6889, 6969, 51413 } drop\n' "$target" "$SSO_CHAIN_IN"
      printf 'add rule inet %s %s udp dport { 6881-6889, 6969, 51413 } drop\n' "$target" "$SSO_CHAIN_IN"
    fi
    printf 'add rule inet %s %s ip saddr @%s drop\n' "$target" "$SSO_CHAIN_IN" "$SSO_SET_BLOCK"
    printf 'add rule inet %s %s ip daddr @%s accept\n' "$target" "$SSO_CHAIN_OUT" "$SSO_SET_WHITE"
    if [[ -f "$STATE_BTFLAG" ]]; then
      printf 'add rule inet %s %s tcp dport { 6881-6889, 6969, 51413 } drop\n' "$target" "$SSO_CHAIN_OUT"
      printf 'add rule inet %s %s udp dport { 6881-6889, 6969, 51413 } drop\n' "$target" "$SSO_CHAIN_OUT"
    fi
    printf 'add rule inet %s %s ip daddr @%s drop\n' "$target" "$SSO_CHAIN_OUT" "$SSO_SET_BLOCK"
    if [[ -n "$old" ]]; then
      printf 'delete table inet %s\n' "$old"
    fi
  } > "$file"
}

nft_activate_staged_table() {
  local target="$1" old="$2"
  local file log
  file="$(mktemp)" || return 1
  log="$(mktemp)" || { rm -f "$file"; return 1; }
  nft_build_activation_file "$target" "$old" "$file"

  if ! nft -c -f "$file" >"$log" 2>&1; then
    err "nftables rejected the final activation transaction; the current active table was preserved."
    sed 's/^/    /' "$log" >&2 || true
    rm -f "$file" "$log"
    return 1
  fi
  if ! nft -f "$file" >"$log" 2>&1; then
    err "nftables failed to commit the final activation transaction; the current active table was preserved."
    sed 's/^/    /' "$log" >&2 || true
    rm -f "$file" "$log"
    return 1
  fi
  rm -f "$file" "$log"
}

_nft_apply_core() {
  _ensure_default_whitelist_core || return 1
  _ensure_state_blocklist_core || return 1

  local active="" target=""
  if ! active="$(nft_active_table)"; then
    return 1
  fi
  target="$(nft_choose_staging_table "$active")"

  if ! nft_create_staging_table "$target"; then
    return 1
  fi
  if ! nft_populate_set_batched "$target" "$SSO_SET_BLOCK" "$STATE_BLOCKLIST"; then
    nft delete table inet "$target" >/dev/null 2>&1 || true
    return 1
  fi
  if ! nft_populate_set_batched "$target" "$SSO_SET_WHITE" "$STATE_WHITELIST"; then
    nft delete table inet "$target" >/dev/null 2>&1 || true
    return 1
  fi
  if ! nft_activate_staged_table "$target" "$active"; then
    nft delete table inet "$target" >/dev/null 2>&1 || true
    return 1
  fi

  local verify_active=""
  if ! verify_active="$(nft_active_table)" || [[ "$verify_active" != "$target" ]]; then
    err "nftables activation committed, but runtime verification could not confirm the expected active SSO table."
    err "Expected active table: $target. Inspect: nft list ruleset"
    return 1
  fi
  nft list set inet "$target" "$SSO_SET_BLOCK" >/dev/null 2>&1 || return 1
  nft list set inet "$target" "$SSO_SET_WHITE" >/dev/null 2>&1 || return 1

  ok "Applied nftables backend using inactive staging + batched sets + atomic activation (INPUT+OUTPUT)."
}

nft_apply() {
  firewall_with_lock _nft_apply_core
}

ipset_prepare_next_sets() {
  local block_next="sso_block_v4_next"
  local white_next="sso_white_v4_next"
  ipset destroy "$block_next" >/dev/null 2>&1 || true
  ipset destroy "$white_next" >/dev/null 2>&1 || true

  local restore_file
  restore_file="$(mktemp)" || return 1
  {
    printf 'create %s hash:net family inet maxelem 200000\n' "$block_next"
    printf 'create %s hash:net family inet maxelem 200000\n' "$white_next"
    local ip
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      printf 'add %s %s\n' "$block_next" "$ip"
    done < "$STATE_BLOCKLIST"
    while IFS= read -r ip; do
      [[ -n "$ip" ]] || continue
      printf 'add %s %s\n' "$white_next" "$ip"
    done < "$STATE_WHITELIST"
  } > "$restore_file"

  if ! ipset restore < "$restore_file"; then
    err "ipset bulk restore failed before live sets were swapped."
    rm -f "$restore_file"
    ipset destroy "$block_next" >/dev/null 2>&1 || true
    ipset destroy "$white_next" >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$restore_file"
}

iptables_build_restore_file() {
  local target="$1"
  {
    echo "*filter"
    echo ":SSO_IN - [0:0]"
    echo ":SSO_OUT - [0:0]"
    if iptables -C INPUT -j SSO_IN >/dev/null 2>&1; then
      echo "-D INPUT -j SSO_IN"
    fi
    if iptables -C OUTPUT -j SSO_OUT >/dev/null 2>&1; then
      echo "-D OUTPUT -j SSO_OUT"
    fi
    echo "-I INPUT 1 -j SSO_IN"
    echo "-I OUTPUT 1 -j SSO_OUT"
    echo "-A SSO_IN -m set --match-set sso_white_v4 src -j RETURN"
    if [[ -f "$STATE_BTFLAG" ]]; then
      echo "-A SSO_IN -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP"
      echo "-A SSO_IN -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP"
    fi
    echo "-A SSO_IN -m set --match-set sso_block_v4 src -j DROP"
    echo "-A SSO_IN -j RETURN"

    echo "-A SSO_OUT -m set --match-set sso_white_v4 dst -j RETURN"
    if [[ -f "$STATE_BTFLAG" ]]; then
      echo "-A SSO_OUT -p tcp -m multiport --dports 6881:6889,6969,51413 -j DROP"
      echo "-A SSO_OUT -p udp -m multiport --dports 6881:6889,6969,51413 -j DROP"
    fi
    echo "-A SSO_OUT -m set --match-set sso_block_v4 dst -j DROP"
    echo "-A SSO_OUT -j RETURN"
    echo "COMMIT"
  } > "$target"
}

ipset_rollback_swaps() {
  local block_next="sso_block_v4_next"
  local white_next="sso_white_v4_next"
  local rc=0
  ipset swap "$block_next" sso_block_v4 >/dev/null 2>&1 || rc=1
  ipset swap "$white_next" sso_white_v4 >/dev/null 2>&1 || rc=1
  return "$rc"
}

ipset_cleanup_next_sets() {
  ipset destroy sso_block_v4_next >/dev/null 2>&1 || true
  ipset destroy sso_white_v4_next >/dev/null 2>&1 || true
}

_ipset_apply_core() {
  _ensure_default_whitelist_core || return 1
  _ensure_state_blocklist_core || return 1

  ipset_prepare_next_sets || return 1

  if ! ipset -exist create sso_block_v4 hash:net family inet maxelem 200000 \
    || ! ipset -exist create sso_white_v4 hash:net family inet maxelem 200000; then
    err "Could not create compatible live ipset sets."
    ipset_cleanup_next_sets
    return 1
  fi

  local restore_file log
  restore_file="$(mktemp)" || {
    ipset_cleanup_next_sets
    return 1
  }
  log="$(mktemp)" || {
    rm -f "$restore_file"
    ipset_cleanup_next_sets
    return 1
  }
  iptables_build_restore_file "$restore_file"

  if ! iptables-restore --test --noflush < "$restore_file" >"$log" 2>&1; then
    err "iptables-restore validation rejected the generated SSO chains before set activation."
    sed 's/^/    /' "$log" >&2 || true
    ipset_cleanup_next_sets
    rm -f "$restore_file" "$log"
    return 1
  fi

  if ! ipset swap sso_block_v4_next sso_block_v4; then
    err "Could not activate the staged blocklist set."
    ipset_cleanup_next_sets
    rm -f "$restore_file" "$log"
    return 1
  fi
  if ! ipset swap sso_white_v4_next sso_white_v4; then
    err "Could not activate the staged whitelist set; restoring blocklist set."
    ipset swap sso_block_v4_next sso_block_v4 >/dev/null 2>&1 || true
    ipset_cleanup_next_sets
    rm -f "$restore_file" "$log"
    return 1
  fi

  if ! iptables-restore --noflush < "$restore_file" >"$log" 2>&1; then
    err "iptables-restore failed to commit the SSO chains; restoring prior ipset contents."
    sed 's/^/    /' "$log" >&2 || true
    ipset_rollback_swaps || true
    ipset_cleanup_next_sets
    rm -f "$restore_file" "$log"
    return 1
  fi

  local verify_ok=1
  ipset list sso_block_v4 >/dev/null 2>&1 || verify_ok=0
  ipset list sso_white_v4 >/dev/null 2>&1 || verify_ok=0
  iptables -S SSO_IN >/dev/null 2>&1 || verify_ok=0
  iptables -S SSO_OUT >/dev/null 2>&1 || verify_ok=0
  iptables -C INPUT -j SSO_IN >/dev/null 2>&1 || verify_ok=0
  iptables -C OUTPUT -j SSO_OUT >/dev/null 2>&1 || verify_ok=0

  if [[ "$verify_ok" != "1" ]]; then
    err "iptables/ipset commit returned success but runtime verification failed; restoring prior ipset contents."
    ipset_rollback_swaps || true
    ipset_cleanup_next_sets
    rm -f "$restore_file" "$log"
    return 1
  fi

  ipset_cleanup_next_sets
  rm -f "$restore_file" "$log"
  ok "Applied iptables+ipset backend with bulk sets and validated chain restore (INPUT+OUTPUT)."
}

ipset_apply() {
  firewall_with_lock _ipset_apply_core
}

firewall_apply_backend() {
  local backend="$1"
  case "$backend" in
    nft) _nft_apply_core ;;
    ipset) _ipset_apply_core ;;
    *) err "Unsupported active firewall backend: $backend"; return 1 ;;
  esac
}

module_firewall_import_blocklist() {
  header
  section "Import blocklist"
  local d
  d="$(backup_create "firewall:import_blocklist")"

  local asset="$ASSETS_DIR/blocklist-ip.ipv4"
  if [[ ! -f "$asset" ]]; then
    err "Missing asset: $asset"
    pause
    return 1
  fi

  if ! firewall_lock_acquire; then
    pause
    return 1
  fi
  local tmp rc=0
  tmp="$(mktemp "$STATE_DIR/.blocklist.import.XXXXXX")" || rc=1
  if [[ "$rc" == "0" ]] && ! sanitize_iplist < "$asset" > "$tmp"; then
    rc=1
  fi
  if [[ "$rc" == "0" ]]; then
    chmod 0644 "$tmp" || rc=1
  fi
  if [[ "$rc" == "0" ]]; then
    mv -f "$tmp" "$STATE_BLOCKLIST" || rc=1
  fi
  [[ "$rc" == "0" ]] || rm -f "${tmp:-}"
  firewall_lock_release

  if [[ "$rc" != "0" ]]; then
    err "Blocklist import failed; the previous state was preserved."
    pause
    return 1
  fi

  ok "Imported blocklist -> $STATE_BLOCKLIST"
  ok "Entries: $(wc -l < "$STATE_BLOCKLIST" | tr -d ' ')"
  ok "Backup: $d"
  pause
}

module_firewall_apply() {
  header
  section "Apply blocklist (INPUT+OUTPUT current v1.x scope)"
  local d
  d="$(backup_create "firewall:apply")"

  local backend
  backend="$(detect_firewall_backend)"
  info "Selected backend: $backend"

  case "$backend" in
    nft)
      if ! nft_apply; then
        err "Firewall apply failed; persistence was not changed."
        pause
        return 1
      fi
      ;;
    ipset)
      if ! ipset_apply; then
        err "Firewall apply failed; persistence was not changed."
        pause
        return 1
      fi
      ;;
    *)
      err "No supported firewall backend found (need usable nft OR iptables+iptables-restore+ipset)."
      pause
      return 1
      ;;
  esac

  if ! firewall_persist_enable; then
    err "Firewall is active now, but boot persistence could not be enabled."
    warn "Fix the systemd error before rebooting."
    pause
    return 1
  fi

  ok "Firewall applied and persistence enabled. Backup: $d"
  pause
}

module_firewall_disable() {
  header
  section "Disable SSO firewall rules"
  local d
  d="$(backup_create "firewall:disable")"

  firewall_lock_acquire || {
    pause
    return 1
  }

  firewall_persist_disable || warn "Persistence cleanup reported an error."
  local rc=0

  if cmd_exists nft; then
    local nft_table
    for nft_table in "$SSO_NFT_TABLE_PRIMARY" "$SSO_NFT_TABLE_SECONDARY"; do
      if nft list table inet "$nft_table" >/dev/null 2>&1; then
        if ! nft delete table inet "$nft_table"; then
          err "Could not remove nftables table inet $nft_table."
          rc=1
        fi
      fi
    done
  fi

  if cmd_exists iptables; then
    while iptables -D INPUT -j SSO_IN >/dev/null 2>&1; do :; done
    while iptables -D OUTPUT -j SSO_OUT >/dev/null 2>&1; do :; done
    iptables -F SSO_IN >/dev/null 2>&1 || true
    iptables -F SSO_OUT >/dev/null 2>&1 || true
    iptables -X SSO_IN >/dev/null 2>&1 || true
    iptables -X SSO_OUT >/dev/null 2>&1 || true
  fi

  if cmd_exists ipset; then
    ipset destroy sso_block_v4 >/dev/null 2>&1 || true
    ipset destroy sso_white_v4 >/dev/null 2>&1 || true
    ipset_cleanup_next_sets
  fi

  if cmd_exists nft; then
    nft list table inet "$SSO_NFT_TABLE_PRIMARY" >/dev/null 2>&1 && rc=1
    nft list table inet "$SSO_NFT_TABLE_SECONDARY" >/dev/null 2>&1 && rc=1
  fi
  if cmd_exists iptables && (iptables -S SSO_IN >/dev/null 2>&1 || iptables -S SSO_OUT >/dev/null 2>&1); then rc=1; fi
  if cmd_exists ipset && (ipset list sso_block_v4 >/dev/null 2>&1 || ipset list sso_white_v4 >/dev/null 2>&1); then rc=1; fi

  firewall_lock_release

  if [[ "$rc" != "0" ]]; then
    err "Some SSO firewall runtime artifacts remain active."
    pause
    return 1
  fi

  ok "SSO firewall rules disabled. Backup: $d"
  pause
}

firewall_reapply_active_backends() {
  local backend
  local found=0
  while IFS= read -r backend; do
    [[ -n "$backend" ]] || continue
    found=1
    firewall_apply_backend "$backend" || return 1
  done < <(firewall_active_backends)
  [[ "$found" == "1" ]] || return 2
}

firewall_update_list_entry_locked() {
  local kind="$1"
  local action="$2"
  local value="$3"
  local canonical
  canonical="$(canonicalize_ipv4_or_cidr "$value")" || {
    err "Invalid IPv4 or CIDR: $value"
    return 1
  }

  local path
  case "$kind" in
    block)
      _ensure_state_blocklist_core || return 1
      path="$STATE_BLOCKLIST"
      ;;
    white)
      _ensure_default_whitelist_core || return 1
      path="$STATE_WHITELIST"
      if [[ "$action" == "remove" && "$canonical" == "$SSO_REQUIRED_WHITELIST" ]]; then
        err "$SSO_REQUIRED_WHITELIST is a managed v1.x safety whitelist entry and cannot be removed here."
        return 1
      fi
      ;;
    *) return 1 ;;
  esac

  local old raw new
  old="$(mktemp "$STATE_DIR/.firewall-old.XXXXXX")" || return 1
  raw="$(mktemp "$STATE_DIR/.firewall-raw.XXXXXX")" || {
    rm -f "$old"
    return 1
  }
  new="$(mktemp "$STATE_DIR/.firewall-new.XXXXXX")" || {
    rm -f "$old" "$raw"
    return 1
  }
  cp -a "$path" "$old" || {
    rm -f "$old" "$raw" "$new"
    return 1
  }

  case "$action" in
    add)
      cat "$path" > "$raw"
      printf '%s\n' "$canonical" >> "$raw"
      ;;
    remove)
      if ! grep -qxF "$canonical" "$path"; then
        info "Exact entry is not present; policy is unchanged: $canonical"
        rm -f "$old" "$raw" "$new"
        return 0
      fi
      grep -vxF "$canonical" "$path" > "$raw" || true
      ;;
    *)
      rm -f "$old" "$raw" "$new"
      return 1
      ;;
  esac

  if ! sanitize_iplist < "$raw" > "$new"; then
    rm -f "$old" "$raw" "$new"
    return 1
  fi
  chmod 0644 "$new" || {
    rm -f "$old" "$raw" "$new"
    return 1
  }
  if cmp -s "$old" "$new"; then
    info "Entry is already covered; policy is unchanged: $canonical"
    rm -f "$old" "$raw" "$new"
    return 0
  fi
  mv -f "$new" "$path" || {
    rm -f "$old" "$raw" "$new"
    return 1
  }
  rm -f "$raw"

  local -a active=()
  if ! firewall_get_active_backends active; then
    err "Could not determine active firewall state safely."
    cp -a "$old" "$path" || true
    rm -f "$old"
    return 1
  fi
  if [[ "${#active[@]}" -gt 0 ]]; then
    local backend
    for backend in "${active[@]}"; do
      if ! firewall_apply_backend "$backend"; then
        err "Runtime firewall update failed; restoring the previous persisted list."
        cp -a "$old" "$path" || err "Could not restore the previous persisted list."
        local rollback_backend
        for rollback_backend in "${active[@]}"; do
          firewall_apply_backend "$rollback_backend" >/dev/null 2>&1 || true
        done
        rm -f "$old"
        return 1
      fi
    done
    ok "Persisted and applied immediately: $canonical"
  else
    ok "Persisted: $canonical"
    info "SSO firewall is not currently active; the entry will apply when the firewall is enabled."
  fi

  rm -f "$old"
}

firewall_update_list_entry() {
  local kind="$1" action="$2" value="$3"
  firewall_with_lock firewall_update_list_entry_locked "$kind" "$action" "$value"
}

module_firewall_blacklist_menu() {
  ensure_state_blocklist || { pause; return 1; }
  while true; do
    header
    section "Blacklist manager"
    echo "Blacklist file: $STATE_BLOCKLIST"
    echo "1) Show blacklist"
    echo "2) Add IP/CIDR (applies immediately if firewall is active)"
    echo "3) Remove IP/CIDR (applies immediately if firewall is active)"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header; section "Blacklist"
        if [[ ! -s "$STATE_BLOCKLIST" ]]; then
          info "Blacklist is empty."
        else
          nl -w2 -s') ' "$STATE_BLOCKLIST"
        fi
        pause
        ;;
      2|3)
        local ip=""
        read_input "Enter IPv4/CIDR: " ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "$ip" ]]; then err "Empty value."; pause; continue; fi
        local action="add"
        [[ "$choice" == "3" ]] && action="remove"
        firewall_update_list_entry block "$action" "$ip" || err "Blacklist update failed."
        pause
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  done
}

module_firewall_whitelist_menu() {
  ensure_default_whitelist || { pause; return 1; }
  while true; do
    header
    section "Whitelist manager"
    echo "Whitelist file: $STATE_WHITELIST"
    echo "Required coverage: $SSO_REQUIRED_WHITELIST (may be represented by a broader allow CIDR)"
    echo "1) Show whitelist"
    echo "2) Add IP/CIDR (applies immediately if firewall is active)"
    echo "3) Remove IP/CIDR (applies immediately if firewall is active)"
    echo "0) Back"
    local choice
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        header; section "Whitelist"
        nl -w2 -s') ' "$STATE_WHITELIST"
        pause
        ;;
      2|3)
        local ip=""
        read_input "Enter IPv4/CIDR: " ip
        ip="${ip//[[:space:]]/}"
        if [[ -z "$ip" ]]; then err "Empty value."; pause; continue; fi
        local action="add"
        [[ "$choice" == "3" ]] && action="remove"
        firewall_update_list_entry white "$action" "$ip" || err "Whitelist update failed."
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
  local preferred
  preferred="$(detect_firewall_backend)"
  info "Preferred available backend: $preferred"

  local active
  active="$(firewall_active_backends | paste -sd ',' -)"
  [[ -n "$active" ]] || active="none"
  info "Active SSO backend(s): $active"
  info "Blocklist entries: $( [[ -f "$STATE_BLOCKLIST" ]] && grep -cve '^$' "$STATE_BLOCKLIST" || echo 0)"
  info "Whitelist entries: $( [[ -f "$STATE_WHITELIST" ]] && grep -cve '^$' "$STATE_WHITELIST" || echo 0)"
  info "Common BitTorrent/P2P port block: $( [[ -f "$STATE_BTFLAG" ]] && echo "ENABLED (best effort)" || echo "disabled" )"
  echo ""

  if cmd_exists nft; then
    local active_nft=""
    if active_nft="$(nft_active_table)" && [[ -n "$active_nft" ]]; then
      info "Active nftables table: inet $active_nft"
      nft list table inet "$active_nft" 2>/dev/null | sed -n '1,140p' || true
    fi
  fi
  if cmd_exists iptables && iptables -S SSO_IN >/dev/null 2>&1; then
    ipset list sso_block_v4 2>/dev/null | sed -n '1,40p' || true
    iptables -S SSO_IN 2>/dev/null || true
    iptables -S SSO_OUT 2>/dev/null || true
  fi
  pause
}

firewall_set_bittorrent_state_locked() {
  local enabled="$1"
  ensure_dirs "$STATE_DIR"
  local was_enabled=0
  [[ -f "$STATE_BTFLAG" ]] && was_enabled=1

  if [[ "$enabled" == "1" ]]; then
    : > "$STATE_BTFLAG" || return 1
  else
    rm -f "$STATE_BTFLAG" || return 1
  fi

  local -a active=()
  if ! firewall_get_active_backends active; then
    if [[ "$was_enabled" == "1" ]]; then : > "$STATE_BTFLAG"; else rm -f "$STATE_BTFLAG"; fi
    err "Could not determine active firewall state safely."
    return 1
  fi
  if [[ "${#active[@]}" -eq 0 ]]; then
    return 0
  fi

  local backend
  for backend in "${active[@]}"; do
    if ! firewall_apply_backend "$backend"; then
      if [[ "$was_enabled" == "1" ]]; then : > "$STATE_BTFLAG"; else rm -f "$STATE_BTFLAG"; fi
      local rollback_backend
      for rollback_backend in "${active[@]}"; do
        firewall_apply_backend "$rollback_backend" >/dev/null 2>&1 || true
      done
      return 1
    fi
  done
}

firewall_set_bittorrent_state() {
  firewall_with_lock firewall_set_bittorrent_state_locked "$1"
}

module_firewall_bittorrent_menu() {
  header
  section "Best-effort common BitTorrent/P2P port block"
  warn "This blocks only common ports (6881-6889, 6969, 51413)."
  warn "Modern P2P traffic can use random ports/encryption; this is not complete protocol detection."

  local choice
  if [[ -f "$STATE_BTFLAG" ]]; then
    info "Common-port blocking is currently ENABLED."
    echo "1) Disable and apply immediately"
    echo "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        if firewall_set_bittorrent_state 0; then
          ok "Common BitTorrent/P2P port block disabled."
        else
          err "Could not disable common-port blocking safely."
        fi
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  else
    info "Common-port blocking is currently disabled."
    echo "1) Enable and apply immediately"
    echo "0) Back"
    prompt_choice "Select an option" choice
    case "$choice" in
      1)
        if firewall_set_bittorrent_state 1; then
          ok "Common BitTorrent/P2P port block enabled."
        else
          err "Could not enable common-port blocking safely."
        fi
        ;;
      0) return ;;
      *) warn "Invalid choice." ;;
    esac
  fi
  pause
}
