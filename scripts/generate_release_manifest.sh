#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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
  assets/blocklist-ip.ipv4
)

payload_path_is_safe() {
  local rel="$1" current="$ROOT_DIR" parent component
  local -a components=()
  parent="${rel%/*}"
  if [[ "$parent" != "$rel" ]]; then
    IFS='/' read -r -a components <<< "$parent"
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
      current="$current/$component"
      [[ -d "$current" && ! -L "$current" ]] || return 1
    done
  fi
  [[ -f "$ROOT_DIR/$rel" && ! -L "$ROOT_DIR/$rel" && -s "$ROOT_DIR/$rel" ]]
}

manifest_paths_match_payload() {
  local manifest="$1" expected actual
  expected="$(mktemp)" || return 1
  actual="$(mktemp)" || { rm -f -- "$expected"; return 1; }
  printf '%s\n' "${PAYLOAD_FILES[@]}" | LC_ALL=C sort > "$expected"
  if ! awk '
    NF != 2 { exit 1 }
    length($1) != 64 || $1 ~ /[^0-9a-fA-F]/ { exit 1 }
    { path=$2; sub(/^\*/, "", path); print path }
  ' "$manifest" | LC_ALL=C sort > "$actual"; then
    rm -f -- "$expected" "$actual"
    return 1
  fi
  cmp -s -- "$expected" "$actual"
  local rc=$?
  rm -f -- "$expected" "$actual"
  return "$rc"
}

validate_manifest_destination() {
  local destination="$1"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || return 1
  fi
}

path_identity() {
  stat -c '%d:%i' -- "$1" 2>/dev/null
}

rename_noreplace() {
  local source="$1" destination="$2"

  # The historical hardening suite injects manifest rename failures with a
  # PATH-scoped mv wrapper. This seam is enabled only by the exported test
  # harness flag plus its per-case MV_FLAG; production always uses renameat2.
  if [[ "${SSO_TEST_ONLY:-0}" == "1" && -n "${MV_FLAG:-}" ]]; then
    mv -fT -- "$source" "$destination"
    return
  fi

  command -v python3 >/dev/null 2>&1 || {
    printf 'Python 3 is required for atomic manifest publication.\n' >&2
    return 1
  }
  python3 - "$source" "$destination" <<'PY_RENAME'
import ctypes
import os
import sys

source = os.fsencode(sys.argv[1])
destination = os.fsencode(sys.argv[2])
libc = ctypes.CDLL(None, use_errno=True)
try:
    renameat2 = libc.renameat2
except AttributeError:
    sys.exit(95)
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, source, -100, destination, 1) != 0:
    err = ctypes.get_errno()
    sys.exit(err if 0 < err < 126 else 1)
PY_RENAME
}

make_absent_sibling_path() {
  local base="$1" candidate i
  for i in {1..64}; do
    candidate="${base}.$$.${RANDOM}.${RANDOM}"
    if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

remove_expected_regular_evidence() {
  local path="$1" expected_identity="$2"
  [[ -n "$path" ]] || return 0
  if [[ ! -e "$path" && ! -L "$path" ]]; then return 0; fi
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(path_identity "$path" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  rm -f -- "$path"
}

atomic_move_noreplace() {
  local source="$1" destination="$2" source_identity destination_identity=""
  source_identity="$(path_identity "$source")" || return 1
  rename_noreplace "$source" "$destination" || return 1
  [[ ! -e "$source" && ! -L "$source" ]] || return 1
  destination_identity="$(path_identity "$destination" 2>/dev/null || true)"
  if [[ -z "$destination_identity" || "$destination_identity" != "$source_identity" ]]; then
    # A concurrent distinct destination is never ours to move or delete.
    return 1
  fi
}

atomic_displace_expected_path() {
  local path="$1" evidence="$2" expected_identity="$3" moved_identity=""
  [[ ! -e "$evidence" && ! -L "$evidence" ]] || return 1
  rename_noreplace "$path" "$evidence" || return 1
  moved_identity="$(path_identity "$evidence" 2>/dev/null || true)"
  if [[ -z "$moved_identity" || "$moved_identity" != "$expected_identity" || -e "$path" || -L "$path" ]]; then
    if [[ -n "$moved_identity" && ! -e "$path" && ! -L "$path" ]]; then
      rename_noreplace "$evidence" "$path" >/dev/null 2>&1 || true
    fi
    return 1
  fi
}

restore_displaced_path() {
  local evidence="$1" destination="$2" expected_identity="$3"
  [[ "$(path_identity "$evidence" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  atomic_move_noreplace "$evidence" "$destination" || return 1
  [[ "$(path_identity "$destination" 2>/dev/null || true)" == "$expected_identity" ]]
}

for f in "${PAYLOAD_FILES[@]}"; do
  payload_path_is_safe "$f" || {
    printf 'Missing or unsafe release payload file: %s\n' "$f" >&2
    exit 1
  }
done

if [[ -L release || ( -e release && ! -d release ) ]]; then
  printf 'Refusing unsafe release directory.\n' >&2
  exit 1
fi
mkdir -p release

manifest_path="release/SHA256SUMS"
validate_manifest_destination "$manifest_path" || {
  printf 'Refusing unsafe release checksum destination.\n' >&2
  exit 1
}

manifest_tmp="$(mktemp release/.SHA256SUMS.publish.XXXXXX)" || exit 1
verify_tmp="$(mktemp release/.SHA256SUMS.verify.XXXXXX)" || exit 1
previous_tmp=""
previous_tmp_identity=""
previous_identity=""
displaced=""
published_identity=""
verify_identity="$(path_identity "$verify_tmp")" || exit 1
failed_path=""

if [[ -f "$manifest_path" && ! -L "$manifest_path" ]]; then
  previous_identity="$(path_identity "$manifest_path")" || exit 1
  previous_tmp="$(mktemp release/.SHA256SUMS.previous.XXXXXX)" || exit 1
  previous_tmp_identity="$(path_identity "$previous_tmp")" || exit 1
  if ! cp -p -- "$manifest_path" "$previous_tmp" \
    || ! cmp -s -- "$manifest_path" "$previous_tmp" \
    || [[ "$(path_identity "$manifest_path" 2>/dev/null || true)" != "$previous_identity" ]]; then
    remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
    printf 'Could not capture and verify the previous release manifest. Previous manifest was not replaced.\n' >&2
    exit 1
  fi
fi

if ! sha256sum "${PAYLOAD_FILES[@]}" > "$manifest_tmp" \
  || [[ ! -f "$manifest_tmp" || -L "$manifest_tmp" || ! -s "$manifest_tmp" ]] \
  || ! manifest_paths_match_payload "$manifest_tmp" \
  || ! cp -p -- "$manifest_tmp" "$verify_tmp" \
  || ! cmp -s -- "$manifest_tmp" "$verify_tmp"; then
  printf 'Could not generate and verify a complete release checksum manifest.\n' >&2
  exit 1
fi
published_identity="$(path_identity "$manifest_tmp")" || exit 1

if [[ -n "$previous_identity" ]]; then
  displaced="$(make_absent_sibling_path 'release/.SHA256SUMS.displaced')" || exit 1
  if ! atomic_displace_expected_path "$manifest_path" "$displaced" "$previous_identity" \
    || [[ ! -f "$displaced" || -L "$displaced" ]] \
    || ! cmp -s -- "$displaced" "$previous_tmp"; then
    printf 'Release manifest changed during atomic displacement. Recovery evidence is preserved at: %s\n' "$previous_tmp" >&2
    exit 1
  fi
fi

if ! atomic_move_noreplace "$manifest_tmp" "$manifest_path"; then
  if [[ -n "$previous_tmp" && ! -e "$manifest_path" && ! -L "$manifest_path" ]]; then
    restore_tmp="$(mktemp release/.restore-SHA256SUMS.XXXXXX)" || {
      printf 'Manifest publication failed; previous recovery evidence is preserved at: %s and %s\n' "$previous_tmp" "$displaced" >&2
      exit 1
    }
    restore_identity="$(path_identity "$restore_tmp")" || exit 1
    if cp -p -- "$previous_tmp" "$restore_tmp" \
      && cmp -s -- "$restore_tmp" "$previous_tmp" \
      && atomic_move_noreplace "$restore_tmp" "$manifest_path" \
      && [[ -f "$manifest_path" && ! -L "$manifest_path" ]] \
      && [[ "$(path_identity "$manifest_path" 2>/dev/null || true)" == "$restore_identity" ]] \
      && cmp -s -- "$manifest_path" "$previous_tmp"; then
      remove_expected_regular_evidence "$manifest_tmp" "$published_identity" >/dev/null 2>&1 || true
      remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
      remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
      if [[ -n "$displaced" && -e "$displaced" ]]; then
        remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || true
      fi
      previous_tmp=""
    else
      printf 'Manifest publication failed; previous recovery evidence is preserved at: %s and %s\n' "$previous_tmp" "$displaced" >&2
    fi
  elif [[ -n "$previous_tmp" ]]; then
    remove_expected_regular_evidence "$manifest_tmp" "$published_identity" >/dev/null 2>&1 || true
    remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
    printf 'Manifest publication raced with another destination; previous recovery evidence is preserved at: %s and %s\n' "$previous_tmp" "$displaced" >&2
  else
    remove_expected_regular_evidence "$manifest_tmp" "$published_identity" >/dev/null 2>&1 || true
    remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
  fi
  exit 1
fi
manifest_tmp=""

current_identity="$(path_identity "$manifest_path" 2>/dev/null || true)"
if [[ ! -f "$manifest_path" || -L "$manifest_path" ]] \
  || [[ "$current_identity" != "$published_identity" ]] \
  || ! cmp -s -- "$manifest_path" "$verify_tmp" \
  || ! manifest_paths_match_payload "$manifest_path"; then
  printf 'Published release checksum manifest failed postcondition verification.\n' >&2

  if [[ -n "$current_identity" && "$current_identity" == "$published_identity" ]]; then
    failed_path="$(make_absent_sibling_path 'release/.SHA256SUMS.failed')" || failed_path=""
    if [[ -n "$failed_path" ]]; then
      atomic_displace_expected_path "$manifest_path" "$failed_path" "$published_identity" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n "$previous_tmp" && ! -e "$manifest_path" && ! -L "$manifest_path" ]]; then
    restore_tmp="$(mktemp release/.restore-SHA256SUMS.XXXXXX)" || {
      printf 'Previous manifest preserved at: %s\n' "$previous_tmp" >&2
      exit 1
    }
    if ! cp -p -- "$previous_tmp" "$restore_tmp" \
      || ! cmp -s -- "$restore_tmp" "$previous_tmp"; then
      printf 'Previous manifest preserved at: %s\n' "$previous_tmp" >&2
      exit 1
    fi
    restore_identity="$(path_identity "$restore_tmp")" || exit 1
    if ! atomic_move_noreplace "$restore_tmp" "$manifest_path" \
      || [[ ! -f "$manifest_path" || -L "$manifest_path" ]] \
      || [[ "$(path_identity "$manifest_path" 2>/dev/null || true)" != "$restore_identity" ]] \
      || ! cmp -s -- "$manifest_path" "$previous_tmp"; then
      printf 'Previous manifest could not be restored automatically; original recovery evidence is preserved at: %s\n' "$previous_tmp" >&2
      exit 1
    fi
    remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
    remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
    if [[ -n "$displaced" && -e "$displaced" ]]; then
      remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || true
    fi
    if [[ -n "$failed_path" && -e "$failed_path" ]]; then
      remove_expected_regular_evidence "$failed_path" "$published_identity" >/dev/null 2>&1 || true
    fi
    previous_tmp=""
  elif [[ -z "$previous_tmp" && -n "$failed_path" && -e "$failed_path" ]]; then
    remove_expected_regular_evidence "$failed_path" "$published_identity" >/dev/null 2>&1 || true
    remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
  fi
  exit 1
fi

remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
if [[ -n "$previous_tmp" ]]; then
  remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
fi
if [[ -n "$displaced" && -e "$displaced" ]]; then
  remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || true
fi
printf 'Wrote release/SHA256SUMS for %d payload files.\n' "${#PAYLOAD_FILES[@]}"
