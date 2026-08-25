#!/usr/bin/env bash
set -Eeuo pipefail

# This module uses globals from sso.sh:
# STATE_DIR, BACKUP_DIR_BASE

SSO_BACKUP_FORMAT="2"

backup_path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

backup_capture_file_state() {
  local src="$1"
  local dst="$2"
  local parent
  parent="$(dirname "$dst")" || return 1
  mkdir -p "$parent" || return 1

  if backup_path_exists "$src"; then
    rm -f -- "${dst}.absent" || return 1
    rm -f -- "$dst" || return 1
    cp -a -- "$src" "$dst" || return 1
    return 0
  fi

  rm -f -- "$dst" || return 1
  : > "${dst}.absent" || return 1
  return 0
}

backup_restore_file_state() {
  local captured="$1"
  local target="$2"

  if backup_path_exists "$captured"; then
    local target_dir tmpdir staged
    target_dir="$(dirname "$target")" || return 1
    mkdir -p "$target_dir" || return 1
    tmpdir="$(mktemp -d "$target_dir/.sso-restore.XXXXXX")" || return 1
    staged="$tmpdir/value"

    # Never delete the live target before the replacement has been copied
    # successfully. This keeps a failed restore from turning into data loss.
    if ! cp -a -- "$captured" "$staged"; then
      rm -rf -- "$tmpdir" 2>/dev/null || true
      return 1
    fi
    if ! mv -Tf -- "$staged" "$target"; then
      rm -rf -- "$tmpdir" 2>/dev/null || true
      return 1
    fi
    rmdir -- "$tmpdir" 2>/dev/null || rm -rf -- "$tmpdir" 2>/dev/null || true
    return 0
  fi

  if [[ -f "${captured}.absent" ]]; then
    rm -f -- "$target" || return 1
    backup_path_exists "$target" && return 1
    return 0
  fi

  return 2
}

backup_create_dir() {
  mkdir -p "$BACKUP_DIR_BASE" || return 1

  local prefix d i
  prefix="$BACKUP_DIR_BASE/$(ts)"
  d="$prefix"

  for ((i=0; i<=9999; i++)); do
    if (( i > 0 )); then
      printf -v d '%s-%04d' "$prefix" "$i"
    fi
    if mkdir "$d" 2>/dev/null; then
      if ! : > "$d/INCOMPLETE"; then
        rmdir -- "$d" 2>/dev/null || true
        return 1
      fi
      printf '%s\n' "$d"
      return 0
    fi
  done

  printf 'Unable to allocate a unique backup directory under %s\n' "$BACKUP_DIR_BASE" >&2
  return 1
}

backup_is_usable_dir() {
  local d="$1"
  local format=""

  [[ -d "$d" ]] || return 1
  [[ ! -e "$d/INCOMPLETE" && ! -L "$d/INCOMPLETE" ]] || return 1
  [[ -f "$d/TAG" ]] || return 1

  if [[ -f "$d/FORMAT" ]]; then
    format="$(cat "$d/FORMAT" 2>/dev/null)" || return 1
    [[ "$format" == "$SSO_BACKUP_FORMAT" ]] || return 1
  fi

  return 0
}

backup_list_names() {
  local root="${1:-$BACKUP_DIR_BASE}"
  local name d
  [[ -d "$root" ]] || return 0

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    d="$root/$name"
    backup_is_usable_dir "$d" || continue
    printf '%s\n' "$name"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
}

backup_capture_sysctl() {
  local d="$1"
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"
  local name

  mkdir -p "$d/sysctl" || return 1
  for name in \
    99-sso-qdisc.conf \
    99-sso-bbr.conf \
    99-sso-net-tuning.conf \
    99-sso-rps.conf; do
    backup_capture_file_state "$sysctl_dir/$name" "$d/sysctl/$name" || return 1
  done

  # This legacy path is not SSO-namespaced, so its prior presence/absence must
  # be explicit before SSO writes it.
  backup_capture_file_state "$modules_load_dir/bbr.conf" "$d/sysctl/bbr.conf" || return 1
}

backup_capture_qdisc() {
  local d="$1"
  mkdir -p "$d/net" || return 1
  local nic
  nic="$(detect_nic)" || return 1
  printf '%s\n' "$nic" > "$d/net/nic" || return 1
  if command -v tc >/dev/null 2>&1; then
    tc qdisc show dev "$nic" > "$d/net/tc-qdisc.txt" 2>/dev/null || true
  fi

  # Capture only runtime controls SSO can credibly restore. If sysctl exists
  # but cannot read a value, fail backup creation rather than certifying a
  # partial v2 snapshot.
  if command -v sysctl >/dev/null 2>&1; then
    local key value
    for key in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
      if ! value="$(sysctl -n "$key" 2>/dev/null)"; then
        return 1
      fi
      printf '%s\n' "$value" > "$d/net/$key" || return 1
    done
  else
    : > "$d/net/runtime.unavailable" || return 1
  fi
}

backup_restore_network_runtime() {
  local d="$1"
  local key f value
  local needs_restore=0

  for key in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
    f="$d/net/$key"
    [[ -s "$f" ]] && needs_restore=1
  done
  [[ "$needs_restore" == "1" ]] || return 2

  # Captured runtime values are an explicit restore obligation. Tool absence
  # is therefore a hard failure, not equivalent to "nothing to restore".
  command -v sysctl >/dev/null 2>&1 || return 1

  local failed=0
  for key in net.core.default_qdisc net.ipv4.tcp_congestion_control; do
    f="$d/net/$key"
    [[ -s "$f" ]] || continue
    value="$(cat "$f")" || return 1
    if ! sysctl -w "$key=$value" >/dev/null 2>&1; then
      warn "Could not restore runtime sysctl $key=$value."
      failed=1
    fi
  done

  return "$failed"
}

backup_firewall_runtime_state() {
  local inspected=0
  local nft_active=0 iptables_active=0 ipset_active=0
  local out

  if command -v nft >/dev/null 2>&1; then
    inspected=1
    if ! out="$(nft list tables 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Eq '^[[:space:]]*table[[:space:]]+(inet|ip)[[:space:]]+sso([[:space:]]|$)'; then
      nft_active=1
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    inspected=1
    if ! out="$(iptables -S 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])SSO_(IN|OUT)([[:space:]]|$)'; then
      iptables_active=1
    fi
  fi

  if command -v ipset >/dev/null 2>&1; then
    inspected=1
    if ! out="$(ipset list -name 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Eq '^(sso_block_v4|sso_white_v4)$'; then
      ipset_active=1
    fi
  fi

  local active_count=$((nft_active + iptables_active + ipset_active))
  if [[ "$active_count" -eq 0 ]]; then
    if [[ "$inspected" -eq 0 ]]; then
      printf 'unknown\n'
    else
      printf 'none\n'
    fi
  elif [[ "$active_count" -gt 1 ]]; then
    printf 'mixed\n'
  elif [[ "$nft_active" -eq 1 ]]; then
    printf 'nft\n'
  elif [[ "$iptables_active" -eq 1 ]]; then
    printf 'iptables\n'
  else
    printf 'ipset\n'
  fi
}

backup_capture_firewall() {
  local d="$1"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  mkdir -p "$d/firewall" || return 1

  backup_capture_file_state \
    "$systemd_dir/sso-firewall.service" \
    "$d/firewall/sso-firewall.service" || return 1
  backup_capture_file_state \
    "$local_sbin_dir/sso-firewall-restore" \
    "$d/firewall/sso-firewall-restore" || return 1

  local runtime
  runtime="$(backup_firewall_runtime_state)" || return 1
  printf '%s\n' "$runtime" > "$d/firewall/runtime.state" || return 1
}

backup_capture_cpu_irq() {
  local d="$1"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  mkdir -p "$d/cpu_irq" || return 1

  backup_capture_file_state \
    "$systemd_dir/sso-cpuirq.service" \
    "$d/cpu_irq/sso-cpuirq.service" || return 1
  backup_capture_file_state \
    "$local_sbin_dir/sso-cpuirq-restore" \
    "$d/cpu_irq/sso-cpuirq-restore" || return 1
}

backup_capture_state() {
  local d="$1"
  mkdir -p "$d/state" || return 1

  backup_capture_file_state "$STATE_DIR/blocklist-ip.ipv4" "$d/state/blocklist-ip.ipv4" || return 1
  backup_capture_file_state "$STATE_DIR/whitelist-ip.ipv4" "$d/state/whitelist-ip.ipv4" || return 1
  backup_capture_file_state "$STATE_DIR/bittorrent-block.enabled" "$d/state/bittorrent-block.enabled" || return 1
  backup_capture_file_state "$STATE_DIR/install_dir" "$d/state/install_dir" || return 1
}

backup_capture_fail2ban() {
  local d="$1"
  local managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  local nginx_marker="${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}"
  mkdir -p "$d/fail2ban" || return 1

  backup_capture_file_state "$managed" "$d/fail2ban/sso.local" || return 1
  backup_capture_file_state "$nginx_marker" "$d/fail2ban/nginx.enabled" || return 1
}

backup_capture_service_state() {
  local d="$1"
  local unit="$2"
  local sd="$d/services/$unit"
  mkdir -p "$sd" || return 1
  command -v systemctl >/dev/null 2>&1 || return 1

  local load="" enabled="" active=""
  load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" || return 1
  case "$load" in
    loaded|masked) ;;
    not-found)
      enabled="not-found"
      active="inactive"
      ;;
    *) return 1 ;;
  esac

  if [[ "$load" != "not-found" ]]; then
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null)" || true
    case "$enabled" in
      enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect|generated|transient) ;;
      *) return 1 ;;
    esac

    active="$(systemctl is-active "$unit" 2>/dev/null)" || true
    case "$active" in
      active|inactive) ;;
      *) return 1 ;;
    esac

    if [[ "$load" == "masked" && "$enabled" != "masked" && "$enabled" != "masked-runtime" ]]; then
      return 1
    fi
  fi

  printf '%s\n' "$load" > "$sd/load" || return 1
  printf '%s\n' "$enabled" > "$sd/enabled" || return 1
  printf '%s\n' "$active" > "$sd/active" || return 1
}

backup_capture_services() {
  local d="$1"
  local unit
  for unit in \
    sso-firewall.service \
    sso-cpuirq.service \
    irqbalance.service \
    fail2ban.service; do
    backup_capture_service_state "$d" "$unit" || return 1
  done
}

backup_mark() {
  local d="$1"
  local tag="$2"
  local verify_tag="" verify_format=""

  # Keep the durable quarantine marker in place while all certification data
  # is written and re-read. Certification becomes visible with one same-dir
  # atomic rename, and there is no fallible verification after that transition.
  printf '%s\n' "$tag" > "$d/TAG" || return 1
  printf '%s\n' "$SSO_BACKUP_FORMAT" > "$d/FORMAT" || return 1
  verify_tag="$(cat "$d/TAG" 2>/dev/null)" || return 1
  verify_format="$(cat "$d/FORMAT" 2>/dev/null)" || return 1
  [[ "$verify_tag" == "$tag" && "$verify_format" == "$SSO_BACKUP_FORMAT" ]] || return 1
  mv -- "$d/INCOMPLETE" "$d/COMPLETE" || return 1
}

backup_create() {
  local tag="$1"
  local d
  d="$(backup_create_dir)" || return 1

  if ! backup_capture_sysctl "$d" \
    || ! backup_capture_qdisc "$d" \
    || ! backup_capture_firewall "$d" \
    || ! backup_capture_cpu_irq "$d" \
    || ! backup_capture_state "$d" \
    || ! backup_capture_fail2ban "$d" \
    || ! backup_capture_services "$d" \
    || ! backup_mark "$d" "$tag"; then
    # Do not attempt recursive cleanup here. A partial cleanup could remove the
    # quarantine marker before failing and make leftover FORMAT/TAG evidence look
    # certified. Keeping the failed directory intact is the fail-closed policy.
    printf 'Backup capture failed; incomplete snapshot remains quarantined at %s and will be ignored.\n' "$d" >&2
    return 1
  fi

  if ! backup_record_ownership_baseline "$tag" "$d"; then
    printf 'Backup is complete, but the durable ownership baseline could not be preserved; refusing the requested mutation.\n' >&2
    return 1
  fi

  printf '%s\n' "$d"
}

module_rollback_list() {
  header
  section "Backups"
  if [[ ! -d "$BACKUP_DIR_BASE" ]]; then
    warn "No backups directory."
    pause; return
  fi
  backup_list_names "$BACKUP_DIR_BASE" | tail -n 50 | sed 's/^/ - /' || true
  pause
}

backup_last_dir() {
  local name=""
  name="$(backup_list_names "$BACKUP_DIR_BASE" | tail -n1 || true)"
  [[ -n "$name" ]] || return 1
  printf '%s/%s\n' "$BACKUP_DIR_BASE" "$name"
}

backup_first_current_format_dir() {
  local name d
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    d="$BACKUP_DIR_BASE/$name"
    [[ -f "$d/FORMAT" ]] || continue
    [[ "$(cat "$d/FORMAT" 2>/dev/null || true)" == "$SSO_BACKUP_FORMAT" ]] || continue
    printf '%s\n' "$d"
    return 0
  done < <(backup_list_names "$BACKUP_DIR_BASE")
  return 1
}

backup_first_tag_in_root() {
  local root="$1"
  local pattern="$2"
  local exclude="${3:-}"
  local name d tag
  [[ -d "$root" ]] || return 1

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    d="$root/$name"
    [[ -n "$exclude" && "$d" == "$exclude" ]] && continue
    backup_is_usable_dir "$d" || continue
    tag="$(cat "$d/TAG" 2>/dev/null)" || continue
    case "$tag" in
      $pattern)
        printf '%s\n' "$d"
        return 0
        ;;
    esac
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
  return 1
}

backup_first_tag_dir() {
  backup_first_tag_in_root "$BACKUP_DIR_BASE" "$1"
}

backup_baseline_store() {
  printf '%s\n' "${SSO_OWNERSHIP_BASELINE_DIR:-$STATE_DIR/ownership-baselines}"
}

backup_baseline_path() {
  local resource="$1"
  printf '%s/%s\n' "$(backup_baseline_store)" "$resource"
}

backup_persist_resource_baseline() {
  local resource="$1"
  local source="$2"
  local base final tmp

  backup_is_usable_dir "$source" || return 1
  base="$(backup_baseline_store)" || return 1
  final="$base/$resource"

  if backup_is_usable_dir "$final"; then
    return 0
  fi
  if [[ -e "$final" || -L "$final" ]]; then
    return 1
  fi

  mkdir -p "$base" || return 1
  tmp="$(mktemp -d "$base/.${resource}.XXXXXX")" || return 1
  if ! cp -a -- "$source/." "$tmp/"; then
    rm -rf -- "$tmp" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$source" > "$tmp/BASELINE_ORIGIN" || {
    rm -rf -- "$tmp" 2>/dev/null || true
    return 1
  }
  if ! mv -- "$tmp" "$final"; then
    rm -rf -- "$tmp" 2>/dev/null || true
    return 1
  fi
  backup_is_usable_dir "$final"
}

backup_previous_install_source() {
  local pattern="$1"
  [[ -n "${SSO_DIR:-}" ]] || return 1
  backup_first_tag_in_root "${SSO_DIR}.bak/backups" "$pattern"
}

backup_snapshot_is_preownership() {
  local resource="$1"
  local source="$2"
  local evidence_mode="${3:-historical}"
  local shared="" shared_value=""

  backup_is_usable_dir "$source" || return 1
  case "$resource" in
    bbr)
      # Presence of SSO namespaced files proves the snapshot is already after
      # an fq/BBR ownership-taking operation.
      backup_path_exists "$source/sysctl/99-sso-qdisc.conf" && return 1
      backup_path_exists "$source/sysctl/99-sso-bbr.conf" && return 1
      shared="$source/sysctl/bbr.conf"

      case "$evidence_mode" in
        current)
          # The current snapshot was captured immediately before the mutation.
          # Explicit presence OR absence is valid only when no earlier matching
          # ownership history exists (enforced by backup_record_ownership_baseline).
          if backup_path_exists "$shared" || [[ -f "${shared}.absent" ]]; then
            return 0
          fi
          return 1
          ;;
        historical)
          # Legacy history needs positive non-SSO evidence. SSO writes exactly
          # "tcp_bbr" to this shared path; absence of namespaced files alone is
          # not chronology proof because those files may have been removed.
          backup_path_exists "$shared" || return 1
          shared_value="$(cat "$shared" 2>/dev/null)" || return 1
          [[ "$shared_value" != "tcp_bbr" ]] || return 1
          return 0
          ;;
        *) return 1 ;;
      esac
      ;;
    fail2ban)
      if [[ -f "$source/fail2ban/sso.local" ]] \
        && grep -Fq '# Managed by Simple Server Optimizer.' "$source/fail2ban/sso.local"; then
        return 1
      fi
      return 0
      ;;
    irqbalance)
      [[ ! -f "${STATE_DIR:-/etc/sso}/installed_irqbalance.marker" ]] || return 1
      # A retained earlier irqbalance operation proves SSO already touched the
      # service; without its durable baseline we preserve ambiguity instead of
      # pretending the current service state is pre-ownership.
      if [[ -n "${SSO_DIR:-}" ]] \
        && backup_first_tag_in_root "${SSO_DIR}.bak/backups" 'cpu_irq:irqbalance' >/dev/null 2>&1; then
        return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

backup_record_ownership_baseline() {
  local tag="$1"
  local current="$2"
  local resource="" pattern="" source="" prior_active="" final=""
  local ambiguous_history=0

  case "$tag" in
    network:fq_bbr) resource="bbr"; pattern="network:fq_bbr" ;;
    fail2ban:*) resource="fail2ban"; pattern="fail2ban:*" ;;
    cpu_irq:irqbalance) resource="irqbalance"; pattern="cpu_irq:irqbalance" ;;
    *) return 0 ;;
  esac

  final="$(backup_baseline_path "$resource")"
  backup_is_usable_dir "$final" && return 0
  if [[ -e "$final" || -L "$final" ]]; then
    return 1
  fi

  # Compatibility recovery is deliberately conservative. A previous-install
  # snapshot is accepted only when it positively proves pre-ownership state.
  # If retained history exists but cannot prove that, current-state fallback is
  # forbidden: ambiguity must remain ambiguity rather than becoming a baseline.
  source="$(backup_previous_install_source "$pattern" 2>/dev/null || true)"
  if [[ -n "$source" ]]; then
    if backup_snapshot_is_preownership "$resource" "$source" historical; then
      backup_persist_resource_baseline "$resource" "$source"
      return $?
    fi
    ambiguous_history=1
  fi

  # Active retained history is never promoted to the original baseline. Its
  # mere existence means the current snapshot cannot be proven to be the first
  # ownership-taking operation when no durable baseline already exists.
  prior_active="$(backup_first_tag_in_root "$BACKUP_DIR_BASE" "$pattern" "$current" 2>/dev/null || true)"
  [[ -z "$prior_active" ]] || ambiguous_history=1

  # On a genuinely first ownership-taking operation, the just-completed
  # snapshot is directly pre-mutation and can become the durable baseline.
  if [[ "$ambiguous_history" == "0" ]] \
    && backup_snapshot_is_preownership "$resource" "$current" current; then
    backup_persist_resource_baseline "$resource" "$current"
    return $?
  fi

  # Legacy history can be irrecoverably ambiguous. That must not block safe
  # namespaced changes, but uninstall will preserve the ambiguous shared state
  # because no durable baseline will exist.
  printf 'No trustworthy pre-ownership baseline could be established for %s; ambiguous shared state will be preserved on uninstall.\n' "$resource" >&2
  return 0
}

backup_migrate_ownership_baselines() {
  [[ -n "${STATE_DIR:-}" && -n "${BACKUP_DIR_BASE:-}" && -n "${SSO_DIR:-}" ]] || return 0

  # Only BBR has enough legacy evidence to recover a durable baseline, and the
  # historical predicate requires positive non-SSO shared-file evidence.
  local final source
  final="$(backup_baseline_path bbr)"
  backup_is_usable_dir "$final" && return 0
  if [[ -e "$final" || -L "$final" ]]; then
    return 1
  fi

  source="$(backup_previous_install_source 'network:fq_bbr' 2>/dev/null || true)"
  [[ -n "$source" ]] || return 0
  backup_snapshot_is_preownership bbr "$source" historical || return 0
  backup_persist_resource_baseline bbr "$source"
}

backup_resource_baseline_dir() {
  local resource="$1"
  local final
  final="$(backup_baseline_path "$resource")"
  backup_is_usable_dir "$final" || return 1
  printf '%s\n' "$final"
}

if [[ -n "${STATE_DIR:-}" && -n "${BACKUP_DIR_BASE:-}" && -n "${SSO_DIR:-}" ]]; then
  if ! backup_migrate_ownership_baselines; then
    if declare -F warn >/dev/null 2>&1; then
      warn "Could not migrate durable ownership baselines; ownership-changing operations will fail closed until this is resolved."
    else
      printf 'Could not migrate durable ownership baselines.\n' >&2
    fi
  fi
fi

backup_service_state_value() {
  local d="$1"
  local unit="$2"
  local key="$3"
  local f="$d/services/$unit/$key"
  [[ -f "$f" ]] || return 2
  cat "$f"
}

backup_current_service_load() {
  local unit="$1"
  local load=""
  load="$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" || return 1
  [[ -n "$load" ]] || return 1
  printf '%s\n' "$load"
}

backup_current_service_enabled() {
  local unit="$1"
  local enabled=""
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null)" || true
  case "$enabled" in
    enabled|enabled-runtime|disabled|masked|masked-runtime|static|indirect|generated|transient) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$enabled"
}

backup_current_service_active() {
  local unit="$1"
  local active=""
  active="$(systemctl is-active "$unit" 2>/dev/null)" || true
  case "$active" in
    active|inactive) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$active"
}

backup_normalize_service_unit_state() {
  local unit="$1"
  systemctl unmask --runtime "$unit" >/dev/null 2>&1 || true
  systemctl unmask "$unit" >/dev/null 2>&1 || true
  systemctl disable --runtime "$unit" >/dev/null 2>&1 || true
  systemctl disable "$unit" >/dev/null 2>&1 || true
}

backup_restore_service_active() {
  local unit="$1"
  local desired="$2"
  local restart_active="${3:-0}"
  local current=""

  case "$desired" in
    active)
      if [[ "$restart_active" == "1" ]]; then
        systemctl restart "$unit" >/dev/null 2>&1 || return 1
      else
        systemctl start "$unit" >/dev/null 2>&1 || return 1
      fi
      ;;
    inactive)
      systemctl stop "$unit" >/dev/null 2>&1 || return 1
      systemctl reset-failed "$unit" >/dev/null 2>&1 || true
      ;;
    *) return 1 ;;
  esac

  current="$(backup_current_service_active "$unit")" || return 1
  [[ "$current" == "$desired" ]]
}

backup_restore_service_state() {
  local d="$1"
  local unit="$2"
  local restart_active="${3:-0}"
  local sd="$d/services/$unit"
  [[ -d "$sd" ]] || return 2
  command -v systemctl >/dev/null 2>&1 || return 1

  local load enabled active current_load current_enabled
  load="$(cat "$sd/load" 2>/dev/null)" || return 1
  enabled="$(cat "$sd/enabled" 2>/dev/null)" || return 1
  active="$(cat "$sd/active" 2>/dev/null)" || return 1

  if [[ "$load" == "not-found" ]]; then
    [[ "$enabled" == "not-found" && "$active" == "inactive" ]] || return 3
    current_load="$(backup_current_service_load "$unit")" || return 1
    [[ "$current_load" == "not-found" ]] || return 1
    return 0
  fi

  case "$load" in loaded|masked) ;; *) return 3 ;; esac
  case "$enabled" in
    masked|masked-runtime|enabled|enabled-runtime|disabled|static|indirect|generated|transient) ;;
    *) return 3 ;;
  esac
  case "$active" in active|inactive) ;; *) return 3 ;; esac

  case "$enabled" in
    enabled|enabled-runtime|disabled|masked|masked-runtime)
      backup_normalize_service_unit_state "$unit"
      case "$enabled" in
        enabled) systemctl enable "$unit" >/dev/null 2>&1 || return 1 ;;
        enabled-runtime) systemctl enable --runtime "$unit" >/dev/null 2>&1 || return 1 ;;
      esac

      backup_restore_service_active "$unit" "$active" "$restart_active" || return 1

      case "$enabled" in
        masked) systemctl mask "$unit" >/dev/null 2>&1 || return 1 ;;
        masked-runtime) systemctl mask --runtime "$unit" >/dev/null 2>&1 || return 1 ;;
      esac
      ;;
    static|indirect|generated|transient)
      current_enabled="$(backup_current_service_enabled "$unit")" || return 1
      [[ "$current_enabled" == "$enabled" ]] || return 1
      backup_restore_service_active "$unit" "$active" "$restart_active" || return 1
      ;;
  esac

  current_enabled="$(backup_current_service_enabled "$unit")" || return 1
  [[ "$current_enabled" == "$enabled" ]] || return 1
  current_load="$(backup_current_service_load "$unit")" || return 1
  case "$current_load" in loaded|masked) ;; *) return 1 ;; esac
  return 0
}

remove_sso_firewall_runtime() {
  local inspected=0 out family i

  if command -v nft >/dev/null 2>&1; then
    inspected=1
    if ! out="$(nft list tables 2>/dev/null)"; then
      return 1
    fi
    for family in inet ip; do
      if printf '%s\n' "$out" | grep -Eq "^[[:space:]]*table[[:space:]]+${family}[[:space:]]+sso([[:space:]]|$)"; then
        nft flush table "$family" sso >/dev/null 2>&1 || return 1
        nft delete table "$family" sso >/dev/null 2>&1 || return 1
      fi
    done
    if ! out="$(nft list tables 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Eq '^[[:space:]]*table[[:space:]]+(inet|ip)[[:space:]]+sso([[:space:]]|$)'; then
      return 1
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    inspected=1

    for ((i=0; i<32; i++)); do
      if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
      if ! printf '%s\n' "$out" | grep -Fqx -- '-A INPUT -j SSO_IN'; then break; fi
      iptables -D INPUT -j SSO_IN >/dev/null 2>&1 || return 1
    done
    if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
    printf '%s\n' "$out" | grep -Fqx -- '-A INPUT -j SSO_IN' && return 1

    for ((i=0; i<32; i++)); do
      if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
      if ! printf '%s\n' "$out" | grep -Fqx -- '-A OUTPUT -j SSO_OUT'; then break; fi
      iptables -D OUTPUT -j SSO_OUT >/dev/null 2>&1 || return 1
    done
    if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
    printf '%s\n' "$out" | grep -Fqx -- '-A OUTPUT -j SSO_OUT' && return 1

    if printf '%s\n' "$out" | grep -Fqx -- '-N SSO_IN'; then
      iptables -F SSO_IN >/dev/null 2>&1 || return 1
      iptables -X SSO_IN >/dev/null 2>&1 || return 1
    fi
    if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
    if printf '%s\n' "$out" | grep -Fqx -- '-N SSO_OUT'; then
      iptables -F SSO_OUT >/dev/null 2>&1 || return 1
      iptables -X SSO_OUT >/dev/null 2>&1 || return 1
    fi
    if ! out="$(iptables -S 2>/dev/null)"; then return 1; fi
    if printf '%s\n' "$out" | grep -Eq '(^|[[:space:]])SSO_(IN|OUT)([[:space:]]|$)'; then
      return 1
    fi
  fi

  if command -v ipset >/dev/null 2>&1; then
    inspected=1
    if ! out="$(ipset list -name 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Fqx -- 'sso_block_v4'; then
      ipset destroy sso_block_v4 >/dev/null 2>&1 || return 1
    fi
    if printf '%s\n' "$out" | grep -Fqx -- 'sso_white_v4'; then
      ipset destroy sso_white_v4 >/dev/null 2>&1 || return 1
    fi
    if ! out="$(ipset list -name 2>/dev/null)"; then
      return 1
    fi
    if printf '%s\n' "$out" | grep -Eq '^(sso_block_v4|sso_white_v4)$'; then
      return 1
    fi
  fi

  [[ "$inspected" -eq 1 ]]
}

restore_captured_state() {
  local format="$1"
  local captured="$2"
  local target="$3"
  local legacy_missing_mode="${4:-preserve}"
  local rc=0

  backup_restore_file_state "$captured" "$target" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    2)
      if [[ "$format" == "$SSO_BACKUP_FORMAT" ]]; then
        return 1
      fi
      if [[ "$legacy_missing_mode" == "remove" ]]; then
        rm -f -- "$target" || return 1
        backup_path_exists "$target" && return 1
        return 0
      fi
      return 2
      ;;
    *) return 1 ;;
  esac
}

restore_from_dir() {
  local d="$1"
  if ! backup_is_usable_dir "$d"; then
    err "Backup is incomplete, invalid, or not a recognized SSO snapshot: $d"
    return 1
  fi

  warn "Restoring SSO-owned configs from: $d"
  warn "This rollback is limited to files/services created or explicitly captured by SSO."

  local format=""
  format="$(cat "$d/FORMAT" 2>/dev/null || true)"
  local sysctl_dir="${SSO_SYSCTL_DIR:-/etc/sysctl.d}"
  local modules_load_dir="${SSO_MODULES_LOAD_DIR:-/etc/modules-load.d}"
  local systemd_dir="${SSO_SYSTEMD_DIR:-/etc/systemd/system}"
  local local_sbin_dir="${SSO_LOCAL_SBIN_DIR:-/usr/local/sbin}"
  local name touched_systemd=0 rc=0

  for name in 99-sso-qdisc.conf 99-sso-bbr.conf 99-sso-net-tuning.conf 99-sso-rps.conf; do
    if ! restore_captured_state "$format" "$d/sysctl/$name" "$sysctl_dir/$name" remove; then
      err "Rollback could not restore captured sysctl state for $name."
      return 1
    fi
  done

  rc=0
  restore_captured_state "$format" "$d/sysctl/bbr.conf" "$modules_load_dir/bbr.conf" preserve || rc=$?
  if [[ "$rc" == "1" ]]; then
    err "Rollback could not restore captured /etc/modules-load.d/bbr.conf state."
    return 1
  elif [[ "$rc" == "2" ]]; then
    warn "Legacy backup has no trustworthy bbr.conf absence evidence; preserving current shared file."
  fi

  for name in blocklist-ip.ipv4 whitelist-ip.ipv4 bittorrent-block.enabled install_dir; do
    rc=0
    restore_captured_state "$format" "$d/state/$name" "$STATE_DIR/$name" preserve || rc=$?
    if [[ "$rc" == "1" ]]; then
      err "Rollback could not restore captured SSO state file: $name"
      return 1
    fi
  done

  run_step "Applying sysctl settings (rollback)" sysctl --system || warn "sysctl apply had errors (continuing with explicit fq/BBR runtime restore)."

  local runtime_rc=0
  backup_restore_network_runtime "$d" || runtime_rc=$?
  if [[ "$runtime_rc" != "0" && "$runtime_rc" != "2" ]]; then
    err "Rollback could not fully restore the captured fq/BBR runtime state."
    return 1
  fi

  rc=0
  restore_captured_state "$format" "$d/cpu_irq/sso-cpuirq.service" "$systemd_dir/sso-cpuirq.service" preserve || rc=$?
  if [[ "$rc" == "1" ]]; then
    err "Rollback could not restore sso-cpuirq.service."
    return 1
  elif [[ "$rc" == "0" ]]; then
    touched_systemd=1
  fi

  rc=0
  restore_captured_state "$format" "$d/cpu_irq/sso-cpuirq-restore" "$local_sbin_dir/sso-cpuirq-restore" preserve || rc=$?
  if [[ "$rc" == "1" ]]; then
    err "Rollback could not restore sso-cpuirq-restore."
    return 1
  fi

  rc=0
  restore_captured_state "$format" "$d/firewall/sso-firewall.service" "$systemd_dir/sso-firewall.service" remove || rc=$?
  if [[ "$rc" != "0" ]]; then
    err "Rollback could not restore sso-firewall.service."
    return 1
  fi
  touched_systemd=1

  rc=0
  restore_captured_state "$format" "$d/firewall/sso-firewall-restore" "$local_sbin_dir/sso-firewall-restore" remove || rc=$?
  if [[ "$rc" != "0" ]]; then
    err "Rollback could not restore sso-firewall-restore."
    return 1
  fi

  if [[ "$touched_systemd" == "1" ]]; then
    if ! run_step "Reloading systemd units (rollback)" systemctl daemon-reload; then
      err "Rollback could not reload systemd after restoring unit files."
      return 1
    fi
  fi

  local cpu_rc=0
  backup_restore_service_state "$d" sso-cpuirq.service 1 || cpu_rc=$?
  if [[ "$cpu_rc" != "0" ]]; then
    if [[ "$cpu_rc" == "2" && "$format" != "$SSO_BACKUP_FORMAT" ]]; then
      warn "Legacy backup has no CPU service lifecycle evidence; leaving service lifecycle unchanged."
    else
      err "Rollback could not safely restore sso-cpuirq.service state."
      return 1
    fi
  fi

  local fw_runtime=""
  fw_runtime="$(cat "$d/firewall/runtime.state" 2>/dev/null || true)"
  if [[ "$fw_runtime" == "none" ]]; then
    if ! remove_sso_firewall_runtime; then
      err "Rollback could not verify removal of SSO firewall runtime state."
      return 1
    fi
  fi

  local fw_rc=0
  backup_restore_service_state "$d" sso-firewall.service 1 || fw_rc=$?
  if [[ "$fw_rc" != "0" ]]; then
    if [[ "$fw_rc" == "2" && "$format" != "$SSO_BACKUP_FORMAT" ]]; then
      warn "Legacy backup has no firewall service lifecycle evidence; leaving service lifecycle unchanged."
    else
      err "Rollback could not safely restore sso-firewall.service state."
      return 1
    fi
  fi

  case "$fw_runtime" in
    nft|iptables|ipset|mixed)
      local fw_active=""
      fw_active="$(backup_service_state_value "$d" sso-firewall.service active 2>/dev/null || true)"
      if [[ "$format" == "$SSO_BACKUP_FORMAT" && "$fw_active" != "active" ]]; then
        err "Prior SSO firewall runtime existed without a restorable active persistence service; exact runtime replay is unsupported."
        return 1
      fi
      ;;
  esac

  # Restore only SSO-owned Fail2Ban state; never overwrite jail.local.
  local f2b_managed="${F2B_SSO_LOCAL:-/etc/fail2ban/jail.d/sso.local}"
  local f2b_nginx_marker="${F2B_NGINX_MARKER:-$STATE_DIR/fail2ban-nginx.enabled}"
  local f2b_touched=0

  rc=0
  restore_captured_state "$format" "$d/fail2ban/sso.local" "$f2b_managed" preserve || rc=$?
  if [[ "$rc" == "1" ]]; then
    err "Rollback could not restore SSO Fail2Ban configuration."
    return 1
  elif [[ "$rc" == "0" ]]; then
    f2b_touched=1
  fi

  rc=0
  restore_captured_state "$format" "$d/fail2ban/nginx.enabled" "$f2b_nginx_marker" preserve || rc=$?
  if [[ "$rc" == "1" ]]; then
    err "Rollback could not restore SSO Fail2Ban nginx marker."
    return 1
  fi

  local desired_f2b_active=""
  desired_f2b_active="$(backup_service_state_value "$d" fail2ban.service active 2>/dev/null || true)"
  if [[ "$f2b_touched" == "1" && "$desired_f2b_active" == "active" ]]; then
    if ! cmd_exists fail2ban-client; then
      err "Fail2Ban validation tooling is unavailable; active service state was not restored."
      return 1
    fi
    if ! fail2ban-client -t; then
      err "Restored SSO Fail2Ban configuration did not validate; Fail2Ban service state was not changed."
      return 1
    fi
  fi

  local f2b_rc=0
  backup_restore_service_state "$d" fail2ban.service 1 || f2b_rc=$?
  if [[ "$f2b_rc" != "0" ]]; then
    if [[ "$f2b_rc" == "2" && "$format" != "$SSO_BACKUP_FORMAT" ]]; then
      if [[ "$f2b_touched" == "1" ]] && command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet fail2ban 2>/dev/null; then
        if ! cmd_exists fail2ban-client || ! fail2ban-client -t; then
          err "Fail2Ban config could not be validated; active legacy service was not restarted."
          return 1
        fi
        if ! run_step "Restarting Fail2Ban (rollback)" systemctl restart fail2ban; then
          err "Could not restart active Fail2Ban after restoring legacy SSO config."
          return 1
        fi
      fi
    else
      err "Rollback could not safely restore fail2ban.service state."
      return 1
    fi
  fi

  local irq_rc=0
  backup_restore_service_state "$d" irqbalance.service 0 || irq_rc=$?
  if [[ "$irq_rc" != "0" ]]; then
    if [[ "$irq_rc" == "2" && "$format" != "$SSO_BACKUP_FORMAT" ]]; then
      warn "Legacy backup has no irqbalance service lifecycle evidence; leaving it unchanged."
    else
      err "Rollback could not safely restore irqbalance.service state."
      return 1
    fi
  fi

  ok "Rollback completed."
  pause
}

module_rollback_last() {
  header
  section "Rollback last backup"
  local d
  d="$(backup_last_dir)"
  if [[ -z "${d:-}" ]] || [[ ! -d "$d" ]]; then
    err "No backups found."
    pause; return
  fi
  if ! restore_from_dir "$d"; then
    err "Rollback did not complete successfully."
    pause
    return 0
  fi
}

module_rollback_choose() {
  header
  section "Rollback choose backup"
  local list
  list="$(backup_list_names "$BACKUP_DIR_BASE" | tail -n 30 || true)"
  if [[ -z "${list:-}" ]]; then
    err "No backups found."
    pause; return
  fi
  echo "$list" | nl -w2 -s') '
  echo "0) Back"
  local idx=""
  prompt_choice "Select number" idx
  [[ "$idx" == "0" ]] && return
  local selected
  selected="$(echo "$list" | sed -n "${idx}p")"
  if [[ -z "${selected:-}" ]]; then
    err "Invalid selection."
    pause; return
  fi
  if ! restore_from_dir "$BACKUP_DIR_BASE/$selected"; then
    err "Rollback did not complete successfully."
    pause
    return 0
  fi
}
