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

restore_previous_manifest() {
  local previous="$1" destination="$2" published_identity="$3" current_identity=""

  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || return 1
    current_identity="$(stat -c '%d:%i' "$destination" 2>/dev/null)" || return 1
    [[ -n "$published_identity" && "$current_identity" == "$published_identity" ]] || return 1
  fi

  if [[ -n "$previous" && -f "$previous" && ! -L "$previous" ]]; then
    mv -fT -- "$previous" "$destination" >/dev/null 2>&1 || return 1
    [[ -f "$destination" && ! -L "$destination" && ! -e "$previous" ]]
    return
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    rm -f -- "$destination" || return 1
  fi
  [[ ! -e "$destination" && ! -L "$destination" ]]
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

manifest_tmp="$(mktemp release/.SHA256SUMS.XXXXXX)" || exit 1
previous_tmp=""
verify_tmp=""
published_identity=""
preserve_previous_tmp=0
cleanup() {
  [[ -z "$manifest_tmp" ]] || rm -f -- "$manifest_tmp" 2>/dev/null || true
  if [[ "$preserve_previous_tmp" != "1" && -n "$previous_tmp" ]]; then
    rm -f -- "$previous_tmp" 2>/dev/null || true
  fi
  [[ -z "$verify_tmp" ]] || rm -f -- "$verify_tmp" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -f "$manifest_path" && ! -L "$manifest_path" ]]; then
  previous_tmp="$(mktemp release/.SHA256SUMS.previous.XXXXXX)" || exit 1
  cp -p -- "$manifest_path" "$previous_tmp" || exit 1
fi

if ! sha256sum "${PAYLOAD_FILES[@]}" > "$manifest_tmp" \
  || [[ ! -f "$manifest_tmp" || -L "$manifest_tmp" || ! -s "$manifest_tmp" ]] \
  || ! manifest_paths_match_payload "$manifest_tmp"; then
  printf 'Could not generate a complete release checksum manifest.\n' >&2
  exit 1
fi

verify_tmp="$(mktemp release/.SHA256SUMS.verify.XXXXXX)" || exit 1
cp -- "$manifest_tmp" "$verify_tmp" || exit 1
published_identity="$(stat -c '%d:%i' "$manifest_tmp" 2>/dev/null)" || exit 1

validate_manifest_destination "$manifest_path" || {
  printf 'Release checksum destination changed to an unsafe type before publication.\n' >&2
  exit 1
}

if ! mv -fT -- "$manifest_tmp" "$manifest_path"; then
  printf 'Could not publish release checksum manifest.\n' >&2
  exit 1
fi
if [[ -e "$manifest_tmp" || -L "$manifest_tmp" ]]; then
  printf 'Release checksum publication reported success without consuming the staging file.\n' >&2
  exit 1
fi
manifest_tmp=""

current_identity=""
if [[ -f "$manifest_path" && ! -L "$manifest_path" ]]; then
  current_identity="$(stat -c '%d:%i' "$manifest_path" 2>/dev/null || true)"
fi
if [[ ! -f "$manifest_path" || -L "$manifest_path" ]] \
  || [[ "$current_identity" != "$published_identity" ]] \
  || ! cmp -s -- "$manifest_path" "$verify_tmp" \
  || ! manifest_paths_match_payload "$manifest_path"; then
  printf 'Published release checksum manifest failed postcondition verification.\n' >&2
  if ! restore_previous_manifest "$previous_tmp" "$manifest_path" "$published_identity"; then
    if [[ -n "$previous_tmp" && -f "$previous_tmp" && ! -L "$previous_tmp" ]]; then
      preserve_previous_tmp=1
      printf 'Previous manifest preserved at: %s\n' "$previous_tmp" >&2
    fi
    printf 'Previous manifest could not be restored automatically.\n' >&2
  else
    previous_tmp=""
  fi
  exit 1
fi

rm -f -- "$verify_tmp"
verify_tmp=""
rm -f -- "$previous_tmp" 2>/dev/null || true
previous_tmp=""
trap - EXIT
printf 'Wrote release/SHA256SUMS for %d payload files.\n' "${#PAYLOAD_FILES[@]}"
