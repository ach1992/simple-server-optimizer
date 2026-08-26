#!/usr/bin/env bash
set -Eeuo pipefail

REPO_SLUG="ach1992/simple-server-optimizer"
INSTALL_DIR="/root/simple-server-optimizer"
STATE_DIR="/etc/sso"
LAUNCHER_PATH="/usr/local/bin/sso"
RUN_AFTER_INSTALL=1

# Runtime path overrides are test-only hooks. The root-executed production
# installer always uses the project-owned paths above so inherited environment
# variables cannot redirect destructive writes or the trusted release source.
if [[ "${SSO_INSTALL_LIB_ONLY:-0}" == "1" ]]; then
  INSTALL_DIR="${SSO_INSTALL_DIR:-$INSTALL_DIR}"
  STATE_DIR="${SSO_STATE_DIR:-$STATE_DIR}"
  LAUNCHER_PATH="${SSO_LAUNCHER_PATH:-$LAUNCHER_PATH}"
  RUN_AFTER_INSTALL="${SSO_INSTALL_RUN_SSO:-$RUN_AFTER_INSTALL}"
fi

SOURCE_PATH="${BASH_SOURCE[0]:-${0:-}}"
if [[ -n "$SOURCE_PATH" && -f "$SOURCE_PATH" ]]; then
  SOURCE_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" && pwd)"
else
  SOURCE_DIR="$PWD"
fi

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

INSTALL_MARKER=".sso-managed-install"
INSTALL_MARKER_SCHEMA="sso-managed-install-v1"
LAUNCHER_MANAGED_MARKER="# Managed by Simple Server Optimizer."
LAUNCHER_SCHEMA_MARKER="# SSO Launcher Schema: 1"

# Exact full-payload fingerprints for the one markerless pre-v1.1 baseline that
# this release supports upgrading in place: main@986aab9aa8540c258ced1c7d8225ff677ae996e7.
# Each value is path:size:Git-blob-SHA1. All PAYLOAD_FILES must match the same
# snapshot before markerless legacy content receives destructive authority.
LEGACY_PAYLOAD_GIT_BLOBS=(
  'install.sh:5708:9b132122b5abbb08271c0db43a5a6d4862cf98c6'
  'sso.sh:6295:07d9afbf77c84c684ea7bb1e114da7e6ef8379b7'
  'modules/utils.sh:5874:4f9642a30cc9edf1f15aa5da50d71b09dc355dad'
  'modules/network.sh:2315:988d29b2aaa94ff2f4223b10399c33aa262fd0b2'
  'modules/cpu_irq.sh:5564:6a897625a9f06764584e98154df9eb0e150c7ba5'
  'modules/firewall.sh:17861:16973d86077285c4da62680b9da5f23ced8573a1'
  'modules/fail2ban.sh:6625:f60eb802dd261a080004d63438829b7a0d9471d2'
  'modules/rollback.sh:36045:c8debe8db4c3e43f3828f85c6b485acb244c3987'
  'modules/uninstall.sh:12270:2285f314bcde21ba8fd3b52d053696e3c6b2141b'
  'assets/whitelist-default.ipv4:220:ae29bcb2a1e8f4c56e30ae770bdfc0fb8f96315a'
  'assets/blocklist-ip.ipv4:63582:84bf7ed722a6d8e17e924f3dcfbe85d647b88994'
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
    exit 1
  fi
}

validate_absolute_runtime_path() {
  local p="$1"
  local canonical=""

  [[ "$p" == /* && "$p" != *$'\n'* && "$p" != *$'\r'* ]] || return 1
  command -v realpath >/dev/null 2>&1 || return 1
  canonical="$(realpath -m -- "$p" 2>/dev/null)" || return 1
  [[ "$p" == "$canonical" && "$p" != "/" ]]
}

path_is_within() {
  local child="$1"
  local parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

render_current_launcher() {
  local state_file_quoted fallback_install_quoted
  printf -v state_file_quoted '%q' "$STATE_DIR/install_dir"
  printf -v fallback_install_quoted '%q' "$INSTALL_DIR"
  cat <<LAUNCHER_SCRIPT
#!/usr/bin/env bash
${LAUNCHER_MANAGED_MARKER}
${LAUNCHER_SCHEMA_MARKER}
set -Eeuo pipefail
INSTALL_DIR_FILE=$state_file_quoted
FALLBACK_INSTALL_DIR=$fallback_install_quoted
if [[ -r "\$INSTALL_DIR_FILE" ]]; then
  INSTALL_DIR="\$(cat "\$INSTALL_DIR_FILE")"
else
  INSTALL_DIR="\$FALLBACK_INSTALL_DIR"
fi
[[ -n "\$INSTALL_DIR" ]] || INSTALL_DIR="\$FALLBACK_INSTALL_DIR"
exec bash "\${INSTALL_DIR}/sso.sh" "\$@"
LAUNCHER_SCRIPT
}

render_transitional_launcher() {
  local state_file_quoted fallback_install_quoted
  printf -v state_file_quoted '%q' "$STATE_DIR/install_dir"
  printf -v fallback_install_quoted '%q' "$INSTALL_DIR"
  cat <<LAUNCHER_SCRIPT
#!/usr/bin/env bash
${LAUNCHER_MANAGED_MARKER}
set -Eeuo pipefail
INSTALL_DIR_FILE=$state_file_quoted
FALLBACK_INSTALL_DIR=$fallback_install_quoted
if [[ -r "\$INSTALL_DIR_FILE" ]]; then
  INSTALL_DIR="\$(cat "\$INSTALL_DIR_FILE")"
else
  INSTALL_DIR="\$FALLBACK_INSTALL_DIR"
fi
[[ -n "\$INSTALL_DIR" ]] || INSTALL_DIR="\$FALLBACK_INSTALL_DIR"
exec bash "\${INSTALL_DIR}/sso.sh" "\$@"
LAUNCHER_SCRIPT
}

render_legacy_launcher() {
  cat <<'LAUNCHER_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR_FILE="/etc/sso/install_dir"
if [[ -r "$INSTALL_DIR_FILE" ]]; then
  INSTALL_DIR="$(cat "$INSTALL_DIR_FILE" 2>/dev/null || true)"
else
  INSTALL_DIR="/root/simple-server-optimizer"
fi
exec bash "${INSTALL_DIR}/sso.sh" "$@"
LAUNCHER_SCRIPT
}

launcher_matches_render() {
  local launcher="$1"
  local render_fn="$2"
  cmp -s -- "$launcher" <( "$render_fn" )
}

launcher_is_current_sso_owned() {
  local launcher="$1"
  [[ -f "$launcher" && ! -L "$launcher" ]] || return 1
  launcher_matches_render "$launcher" render_current_launcher
}

launcher_is_sso_owned() {
  local launcher="$1"
  [[ -f "$launcher" && ! -L "$launcher" ]] || return 1
  launcher_matches_render "$launcher" render_current_launcher \
    || launcher_matches_render "$launcher" render_transitional_launcher \
    || launcher_matches_render "$launcher" render_legacy_launcher
}
validate_runtime_paths() {
  local p
  for p in "$INSTALL_DIR" "$STATE_DIR" "$LAUNCHER_PATH"; do
    validate_absolute_runtime_path "$p" || {
      err "SSO paths must be canonical absolute paths without dot segments, aliases, or line breaks: $p"
      return 1
    }
    case "$p" in
      /root|/home|/etc|/usr|/var|/tmp|/opt|/srv)
        err "Refusing unsafe broad runtime path: $p"
        return 1
        ;;
    esac
  done

  if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || {
      err "Existing installation path is not a regular directory: $INSTALL_DIR"
      return 1
    }
  fi
  if [[ -e "$STATE_DIR" || -L "$STATE_DIR" ]]; then
    [[ -d "$STATE_DIR" && ! -L "$STATE_DIR" ]] || {
      err "Existing state path is not a regular directory: $STATE_DIR"
      return 1
    }
  fi
  if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]]; then
    launcher_is_sso_owned "$LAUNCHER_PATH" || {
      err "Refusing to replace an existing launcher path that is not SSO-owned: $LAUNCHER_PATH"
      return 1
    }
  fi

  local backup_dir="${INSTALL_DIR}.bak"
  if path_is_within "$STATE_DIR" "$INSTALL_DIR" \
    || path_is_within "$INSTALL_DIR" "$STATE_DIR" \
    || path_is_within "$STATE_DIR" "$backup_dir"; then
    err "State directory must remain independent of the replaceable installation and backup trees."
    return 1
  fi

  if path_is_within "$LAUNCHER_PATH" "$INSTALL_DIR" \
    || path_is_within "$LAUNCHER_PATH" "$backup_dir"; then
    err "Launcher path must remain outside the replaceable installation and backup trees."
    return 1
  fi
}

ensure_tools() {
  if command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
    return 0
  fi

  warn "curl/sha256sum are required. Installing curl, CA certificates, and coreutils..."
  run_step "Updating package index" apt-get update -y || return 1
  run_step "Installing download/integrity tools" apt-get install -y curl ca-certificates coreutils || return 1
  command -v curl >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1
}

payload_path_is_safe() {
  local root="$1"
  local rel="$2"
  local current="$root" parent component
  local -a components=()

  [[ -d "$root" && ! -L "$root" ]] || return 1
  [[ -n "$rel" && "$rel" != /* && "$rel" != *$'\n'* && "$rel" != *$'\r'* ]] || return 1

  parent="${rel%/*}"
  if [[ "$parent" != "$rel" ]]; then
    IFS='/' read -r -a components <<< "$parent"
    for component in "${components[@]}"; do
      [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
      current="$current/$component"
      [[ -d "$current" && ! -L "$current" ]] || return 1
    done
  fi

  [[ -f "$root/$rel" && ! -L "$root/$rel" && -s "$root/$rel" ]]
}

has_payload() {
  local root="$1"
  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    payload_path_is_safe "$root" "$f" || return 1
  done
}

managed_install_marker_expected() {
  printf 'schema=%s\nrepository=%s\n' "$INSTALL_MARKER_SCHEMA" "$REPO_SLUG"
}

managed_install_marker_is_valid() {
  local root="$1"
  local marker="$root/$INSTALL_MARKER"
  [[ -f "$marker" && ! -L "$marker" ]] || return 1
  cmp -s -- "$marker" <(managed_install_marker_expected)
}

legacy_git_blob_identity() {
  local file="$1" size output sha
  [[ -f "$file" && ! -L "$file" ]] || return 1
  command -v sha1sum >/dev/null 2>&1 || return 1
  command -v wc >/dev/null 2>&1 || return 1

  size="$(wc -c < "$file")" || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  output="$({ printf 'blob %s\0' "$size"; cat -- "$file"; } | sha1sum)" || return 1
  sha="${output%% *}"
  [[ ${#sha} -eq 40 && "$sha" != *[!0-9a-f]* ]] || return 1
  printf '%s:%s\n' "$size" "$sha"
}

legacy_install_is_sso_owned() {
  local root="$1" i f entry expected_path expected_identity actual_identity
  has_payload "$root" || return 1
  [[ ${#LEGACY_PAYLOAD_GIT_BLOBS[@]} -eq ${#PAYLOAD_FILES[@]} ]] || return 1

  for i in "${!PAYLOAD_FILES[@]}"; do
    f="${PAYLOAD_FILES[$i]}"
    entry="${LEGACY_PAYLOAD_GIT_BLOBS[$i]}"
    expected_path="${entry%%:*}"
    expected_identity="${entry#*:}"
    [[ "$expected_path" == "$f" ]] || return 1
    [[ "$expected_identity" == *:* ]] || return 1
    actual_identity="$(legacy_git_blob_identity "$root/$f")" || return 1
    [[ "$actual_identity" == "$expected_identity" ]] || return 1
  done
}

installation_is_sso_owned() {
  local root="$1"
  local marker="$root/$INSTALL_MARKER"
  [[ -d "$root" && ! -L "$root" ]] || return 1
  has_payload "$root" || return 1

  if [[ -e "$marker" || -L "$marker" ]]; then
    managed_install_marker_is_valid "$root"
    return
  fi

  legacy_install_is_sso_owned "$root"
}

write_managed_install_marker() {
  local root="$1"
  local marker="$root/$INSTALL_MARKER"
  [[ -d "$root" && ! -L "$root" ]] || return 1
  [[ ! -e "$marker" && ! -L "$marker" ]] || return 1

  if ! managed_install_marker_expected > "$marker" || ! chmod 0644 "$marker"; then
    rm -f -- "$marker" 2>/dev/null || true
    return 1
  fi
  managed_install_marker_is_valid "$root"
}
has_local_payload() {
  has_payload "$SOURCE_DIR"
}

validate_payload() {
  local root="$1"
  has_payload "$root" || {
    err "Payload is incomplete: $root"
    return 1
  }

  grep -q '^#!/usr/bin/env bash' "$root/install.sh" || {
    err "install.sh has an unexpected header."
    return 1
  }
  grep -q '^#!/usr/bin/env bash' "$root/sso.sh" || {
    err "sso.sh has an unexpected header."
    return 1
  }

  local scripts=("$root/install.sh" "$root/sso.sh")
  local f
  for f in "$root"/modules/*.sh; do
    scripts+=("$f")
  done
  bash -n "${scripts[@]}"
}

validate_existing_install_state() {
  local backup="${INSTALL_DIR}.bak"
  local has_current=0

  if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    installation_is_sso_owned "$INSTALL_DIR" || {
      err "Refusing to replace an existing path without positive SSO installation ownership: $INSTALL_DIR"
      return 1
    }
    has_current=1
  fi

  if [[ -e "$backup" || -L "$backup" ]]; then
    [[ "$has_current" == "1" ]] || {
      err "A recovery backup exists without a live SSO installation; recover or move it before reinstalling: $backup"
      return 1
    }
    installation_is_sso_owned "$backup" || {
      err "Refusing to delete or replace a recovery path without positive SSO installation ownership: $backup"
      return 1
    }
  fi
}
curl_fetch() {
  local url="$1"
  local out="$2"
  # Keep options compatible with Debian 10's curl 7.64.x.
  if ! curl -fL --retry 5 --retry-delay 1 -sS "$url" -o "$out"; then
    rm -f -- "$out"
    return 1
  fi
  [[ -s "$out" ]] || {
    err "Downloaded file is empty: $url"
    return 1
  }
}

semver_identifiers_are_valid() {
  local identifiers="$1"
  local reject_numeric_leading_zero="$2"
  local rest="$identifiers" identifier

  [[ -n "$rest" ]] || return 1
  while :; do
    identifier="${rest%%.*}"
    [[ -n "$identifier" && "$identifier" =~ ^[0-9A-Za-z-]+$ ]] || return 1
    if [[ "$reject_numeric_leading_zero" == "1" && "$identifier" =~ ^[0-9]+$ \
      && ${#identifier} -gt 1 && "$identifier" == 0* ]]; then
      return 1
    fi
    [[ "$rest" == *.* ]] || break
    rest="${rest#*.}"
    [[ -n "$rest" ]] || return 1
  done
}

validate_release_ref() {
  local ref="$1" version core_pre core prerelease="" build=""

  [[ "$ref" == v* && "$ref" != *$'\n'* && "$ref" != *$'\r'* && "$ref" != *[[:space:]]* \
    && "$ref" != */* ]] || return 1
  version="${ref#v}"

  if [[ "$version" == *+* ]]; then
    [[ "$version" != *+*+* ]] || return 1
    build="${version#*+}"
    core_pre="${version%%+*}"
    semver_identifiers_are_valid "$build" 0 || return 1
  else
    core_pre="$version"
  fi

  if [[ "$core_pre" == *-* ]]; then
    core="${core_pre%%-*}"
    prerelease="${core_pre#*-}"
    semver_identifiers_are_valid "$prerelease" 1 || return 1
  else
    core="$core_pre"
  fi

  [[ "$core" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}
resolve_release_ref() {
  ensure_tools || return 1
  local effective="" prefix ref
  effective="$(curl -fLsS --retry 3 --retry-delay 1 -o /dev/null -w '%{url_effective}' \
    "https://github.com/${REPO_SLUG}/releases/latest")" || return 1

  prefix="https://github.com/${REPO_SLUG}/releases/tag/"
  [[ "$effective" == "$prefix"* ]] || {
    err "Latest release did not resolve to the official repository release path."
    return 1
  }
  ref="${effective#"$prefix"}"
  [[ "$ref" != */* ]] || return 1
  validate_release_ref "$ref" || {
    err "No valid published SSO release could be resolved."
    return 1
  }
  printf '%s\n' "$ref"
}

github_api_get() {
  local url="$1"
  curl -fLsS --retry 3 --retry-delay 1 \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$url"
}

github_object_identity_from_json() {
  awk '
    function die() { exit 2 }
    function ws(c) { return c == " " || c == "\t" || c == "\r" || c == "\n" }
    function skip_ws(    c) {
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (!ws(c)) break
        pos++
      }
    }
    function parse_string(    c,e,out,hex) {
      skip_ws()
      if (substr(s, pos, 1) != "\"") die()
      pos++
      out = ""
      string_escaped = 0
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (c == "\"") {
          pos++
          parsed = out
          return
        }
        if (c == "\\") {
          string_escaped = 1
          pos++
          if (pos > n) die()
          e = substr(s, pos, 1)
          if (e == "u") {
            hex = substr(s, pos + 1, 4)
            if (length(hex) != 4 || hex !~ /^[0-9A-Fa-f]+$/) die()
            out = out "\\u" hex
            pos += 5
            continue
          }
          if (e !~ /^["\\\/bfnrt]$/) die()
          out = out "\\" e
          pos++
          continue
        }
        if (c ~ /[[:cntrl:]]/) die()
        out = out c
        pos++
      }
      die()
    }
    function parse_key() {
      parse_string()
      if (string_escaped) die()
      key = parsed
    }
    function expect(ch) {
      skip_ws()
      if (substr(s, pos, 1) != ch) die()
      pos++
    }
    function skip_value(    c,token) {
      skip_ws()
      c = substr(s, pos, 1)
      if (c == "\"") {
        parse_string()
        return
      }
      if (c == "{") {
        skip_object()
        return
      }
      if (c == "[") {
        skip_array()
        return
      }
      token = ""
      while (pos <= n) {
        c = substr(s, pos, 1)
        if (ws(c) || c == "," || c == "]" || c == "}") break
        token = token c
        pos++
      }
      if (token !~ /^(true|false|null|-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?)$/) die()
    }
    function skip_object(    c) {
      nesting++
      if (nesting > 32) die()
      expect("{")
      skip_ws()
      if (substr(s, pos, 1) == "}") { pos++; nesting--; return }
      while (1) {
        parse_key()
        expect(":")
        skip_value()
        skip_ws()
        c = substr(s, pos, 1)
        if (c == "}") { pos++; nesting--; return }
        if (c != ",") die()
        pos++
      }
    }
    function skip_array(    c) {
      nesting++
      if (nesting > 32) die()
      expect("[")
      skip_ws()
      if (substr(s, pos, 1) == "]") { pos++; nesting--; return }
      while (1) {
        skip_value()
        skip_ws()
        c = substr(s, pos, 1)
        if (c == "]") { pos++; nesting--; return }
        if (c != ",") die()
        pos++
      }
    }
    function parse_identity_object(    c,value,escaped) {
      expect("{")
      identity_sha = ""
      identity_type = ""
      seen_sha = seen_type = seen_url = 0
      skip_ws()
      if (substr(s, pos, 1) == "}") die()
      while (1) {
        parse_key()
        expect(":")
        if (key != "sha" && key != "type" && key != "url") die()
        parse_string()
        escaped = string_escaped
        value = parsed
        if (escaped && (key == "sha" || key == "type")) die()
        if (key == "sha") {
          if (++seen_sha != 1) die()
          identity_sha = value
        } else if (key == "type") {
          if (++seen_type != 1) die()
          identity_type = value
        } else {
          if (++seen_url != 1) die()
        }
        skip_ws()
        c = substr(s, pos, 1)
        if (c == "}") { pos++; break }
        if (c != ",") die()
        pos++
      }
      if (seen_sha != 1 || seen_type != 1) die()
      if (identity_sha !~ /^[0-9a-f]+$/ || length(identity_sha) != 40) die()
      if (identity_type != "commit" && identity_type != "tag") die()
    }
    function parse_root(    c) {
      expect("{")
      object_count = 0
      skip_ws()
      if (substr(s, pos, 1) == "}") die()
      while (1) {
        parse_key()
        expect(":")
        if (key == "object") {
          object_count++
          if (object_count != 1) die()
          parse_identity_object()
        } else {
          skip_value()
        }
        skip_ws()
        c = substr(s, pos, 1)
        if (c == "}") { pos++; break }
        if (c != ",") die()
        pos++
      }
      skip_ws()
      if (pos <= n || object_count != 1) die()
      print identity_type "\t" identity_sha
    }
    { json = json $0 "\n" }
    END {
      s = json
      n = length(s)
      pos = 1
      nesting = 0
      parse_root()
    }
  '
}

resolve_tag_commit_sha() {
  local ref="$1"
  validate_release_ref "$ref" || return 1

  local json identity type sha depth=0
  json="$(github_api_get "https://api.github.com/repos/${REPO_SLUG}/git/ref/tags/${ref}")" || return 1
  identity="$(printf '%s\n' "$json" | github_object_identity_from_json)" || return 1
  IFS=$'\t' read -r type sha <<< "$identity"

  while [[ "$type" == "tag" && "$depth" -lt 5 ]]; do
    json="$(github_api_get "https://api.github.com/repos/${REPO_SLUG}/git/tags/${sha}")" || return 1
    identity="$(printf '%s\n' "$json" | github_object_identity_from_json)" || return 1
    IFS=$'\t' read -r type sha <<< "$identity"
    depth=$((depth + 1))
  done

  [[ "$type" == "commit" && "$sha" =~ ^[0-9a-f]{40}$ ]] || {
    err "Release tag did not resolve to a commit SHA within the allowed annotation depth."
    return 1
  }
  printf '%s\n' "$sha"
}
verify_release_manifest() {
  local root="$1"
  local manifest="$root/release/SHA256SUMS"
  local f

  [[ -d "$root" && ! -L "$root" ]] || {
    err "Release payload root is not a regular directory."
    return 1
  }
  payload_path_is_safe "$root" "release/SHA256SUMS" || {
    err "Release checksum manifest is missing, empty, symlinked, or has an unsafe parent path."
    return 1
  }
  for f in "${PAYLOAD_FILES[@]}"; do
    payload_path_is_safe "$root" "$f" || {
      err "Release payload path is missing, empty, symlinked, or non-regular: $f"
      return 1
    }
  done

  local expected actual
  expected="$(mktemp)" || return 1
  actual="$(mktemp)" || {
    rm -f "$expected"
    return 1
  }

  printf '%s\n' "${PAYLOAD_FILES[@]}" | LC_ALL=C sort > "$expected"

  if ! awk '
    NF == 0 { next }
    NF != 2 { exit 2 }
    length($1) != 64 || $1 ~ /[^0-9a-fA-F]/ { exit 3 }
    {
      path=$2
      sub(/^\*/, "", path)
      if (path ~ /^\// || path ~ /(^|\/)\.\.($|\/)/) exit 4
      print path
    }
  ' "$manifest" | LC_ALL=C sort > "$actual"; then
    rm -f "$expected" "$actual"
    err "Release checksum manifest has an invalid format."
    return 1
  fi

  if ! cmp -s "$expected" "$actual"; then
    rm -f "$expected" "$actual"
    err "Release checksum manifest does not describe the exact SSO payload."
    return 1
  fi
  rm -f "$expected" "$actual"

  if ! (cd "$root" && sha256sum -c release/SHA256SUMS >/dev/null); then
    err "Release checksum verification failed."
    return 1
  fi

  payload_path_is_safe "$root" "release/SHA256SUMS" || return 1
  for f in "${PAYLOAD_FILES[@]}"; do
    payload_path_is_safe "$root" "$f" || return 1
  done
}
download_release_payload() {
  local ref="$1"
  local target="$2"
  local base="https://raw.githubusercontent.com/${REPO_SLUG}/${ref}"

  mkdir -p "$target/release" || return 1
  run_step "Downloading release checksum manifest" \
    curl_fetch "${base}/release/SHA256SUMS" "$target/release/SHA256SUMS" || return 1

  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    mkdir -p "$target/$(dirname "$f")" || return 1
    run_step "Downloading ${f}" curl_fetch "${base}/${f}" "$target/$f" || return 1
  done

  info "Verifying release checksums..."
  verify_release_manifest "$target" || return 1
  ok "Release checksums verified."

  validate_payload "$target"
}

stage_local_payload() {
  local source="$1"
  local target="$2"
  has_payload "$source" || {
    err "Local payload is incomplete: $source"
    return 1
  }

  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    mkdir -p "$target/$(dirname "$f")" || return 1
    cp -a "$source/$f" "$target/$f" || return 1
  done
  validate_payload "$target"
}

path_identity() {
  local path="$1"
  stat -c '%d:%i' -- "$path" 2>/dev/null
}

rename_noreplace() {
  local source="$1"
  local destination="$2"

  # Existing installer regressions override mv while loading the installer as a
  # library. Preserve those bounded fault-injection seams without weakening the
  # production path or the new real-rename race tests.
  if [[ "${SSO_INSTALL_LIB_ONLY:-0}" == "1" ]] && declare -F mv >/dev/null 2>&1; then
    mv -fT -- "$source" "$destination"
    return
  fi

  command -v python3 >/dev/null 2>&1 || {
    err "Python 3 is required for atomic no-replace publication."
    return 1
  }

  python3 - "$source" "$destination" <<'PY_RENAME'
import ctypes
import errno
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
AT_FDCWD = -100
RENAME_NOREPLACE = 1
if renameat2(AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE) != 0:
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

atomic_move_noreplace() {
  local source="$1" destination="$2" source_identity destination_identity=""
  [[ -e "$source" || -L "$source" ]] || return 1
  source_identity="$(path_identity "$source")" || return 1

  if ! rename_noreplace "$source" "$destination"; then
    return 1
  fi

  if [[ -e "$source" || -L "$source" ]]; then
    return 1
  fi
  destination_identity="$(path_identity "$destination" 2>/dev/null || true)"
  if [[ -z "$destination_identity" || "$destination_identity" != "$source_identity" ]]; then
    # A distinct destination inode may have appeared immediately after the
    # successful rename. It is not ours, so leave it untouched and fail closed.
    return 1
  fi
}

restore_displaced_path() {
  local evidence="$1" destination="$2" expected_identity="$3"
  [[ -e "$evidence" || -L "$evidence" ]] || return 1
  [[ "$(path_identity "$evidence" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  atomic_move_noreplace "$evidence" "$destination" || return 1
  [[ "$(path_identity "$destination" 2>/dev/null || true)" == "$expected_identity" ]]
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

remove_expected_regular_evidence() {
  local path="$1" expected_identity="$2"
  [[ -n "$path" ]] || return 0
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(path_identity "$path" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  rm -f -- "$path"
}

publish_regular_file_transactional() {
  local stage="$1" destination="$2" label="$3"
  local directory base stage_identity verify_tmp="" verify_identity=""
  local previous_tmp="" previous_tmp_identity="" previous_identity="" displaced=""
  local restore_tmp="" restore_identity="" current_identity="" failed_path=""

  [[ -f "$stage" && ! -L "$stage" ]] || return 1
  validate_regular_publish_destination "$destination" "$label" || return 1
  directory="$(dirname -- "$destination")"
  base="$(basename -- "$destination")"
  stage_identity="$(path_identity "$stage")" || return 1

  verify_tmp="$(mktemp "$directory/.${base}.verify.XXXXXX")" || return 1
  verify_identity="$(path_identity "$verify_tmp")" || return 1
  if ! cp -p -- "$stage" "$verify_tmp" || ! cmp -s -- "$stage" "$verify_tmp"; then
    remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -f "$destination" && ! -L "$destination" ]]; then
    previous_identity="$(path_identity "$destination")" || return 1
    previous_tmp="$(mktemp "$directory/.${base}.previous.XXXXXX")" || return 1
    previous_tmp_identity="$(path_identity "$previous_tmp")" || return 1
    if ! cp -p -- "$destination" "$previous_tmp" \
      || ! cmp -s -- "$destination" "$previous_tmp" \
      || [[ "$(path_identity "$destination" 2>/dev/null || true)" != "$previous_identity" ]] \
      || [[ ! -f "$destination" || -L "$destination" ]]; then
      remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
      remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
      return 1
    fi

    displaced="$(make_absent_sibling_path "$directory/.${base}.displaced")" || return 1
    if ! atomic_displace_expected_path "$destination" "$displaced" "$previous_identity"; then
      err "$label destination changed during atomic displacement; previous copy is preserved at: $previous_tmp"
      return 1
    fi
    if [[ ! -f "$displaced" || -L "$displaced" ]] || ! cmp -s -- "$displaced" "$previous_tmp"; then
      err "$label displaced evidence failed verification; previous copy is preserved at: $previous_tmp"
      return 1
    fi
  fi

  if ! atomic_move_noreplace "$stage" "$destination"; then
    if [[ -n "$previous_tmp" && ! -e "$destination" && ! -L "$destination" ]]; then
      restore_tmp="$(mktemp "$directory/.${base}.restore.XXXXXX")" || {
        err "$label publication failed; previous copy is preserved at: $previous_tmp${displaced:+ and $displaced}"
        return 1
      }
      restore_identity="$(path_identity "$restore_tmp")" || return 1
      if cp -p -- "$previous_tmp" "$restore_tmp" \
        && cmp -s -- "$restore_tmp" "$previous_tmp" \
        && atomic_move_noreplace "$restore_tmp" "$destination" \
        && [[ -f "$destination" && ! -L "$destination" ]] \
        && [[ "$(path_identity "$destination" 2>/dev/null || true)" == "$restore_identity" ]] \
        && cmp -s -- "$destination" "$previous_tmp"; then
        remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
        remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
        if [[ -n "$displaced" && -e "$displaced" ]]; then
          remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || true
        fi
      else
        err "$label publication failed; recovery evidence is preserved at: $previous_tmp${displaced:+ and $displaced}"
      fi
    elif [[ -n "$previous_tmp" ]]; then
      err "$label publication raced with another destination; recovery evidence is preserved at: $previous_tmp${displaced:+ and $displaced}"
    else
      remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  current_identity="$(path_identity "$destination" 2>/dev/null || true)"
  if [[ ! -f "$destination" || -L "$destination" ]] \
    || [[ "$current_identity" != "$stage_identity" ]] \
    || ! cmp -s -- "$destination" "$verify_tmp"; then
    if [[ -n "$current_identity" && "$current_identity" == "$stage_identity" ]]; then
      failed_path="$(make_absent_sibling_path "$directory/.${base}.failed")" || true
      if [[ -n "$failed_path" ]]; then
        atomic_displace_expected_path "$destination" "$failed_path" "$stage_identity" >/dev/null 2>&1 || true
      fi
    fi

    if [[ -n "$previous_tmp" && ! -e "$destination" && ! -L "$destination" ]]; then
      restore_tmp="$(mktemp "$directory/.${base}.restore.XXXXXX")" || {
        err "$label recovery could not create restore staging; previous copy is preserved at: $previous_tmp"
        return 1
      }
      restore_identity="$(path_identity "$restore_tmp")" || return 1
      if ! cp -p -- "$previous_tmp" "$restore_tmp" \
        || ! cmp -s -- "$restore_tmp" "$previous_tmp" \
        || ! atomic_move_noreplace "$restore_tmp" "$destination" \
        || [[ ! -f "$destination" || -L "$destination" ]] \
        || [[ "$(path_identity "$destination" 2>/dev/null || true)" != "$restore_identity" ]] \
        || ! cmp -s -- "$destination" "$previous_tmp"; then
        err "$label recovery failed or was ambiguous; previous copy is preserved at: $previous_tmp${displaced:+ and $displaced}"
        return 1
      fi
      remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
      remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
      if [[ -n "$displaced" && -e "$displaced" ]]; then
        remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || true
      fi
      if [[ -n "$failed_path" && -e "$failed_path" ]]; then
        remove_expected_regular_evidence "$failed_path" "$stage_identity" >/dev/null 2>&1 || true
      fi
    elif [[ -z "$previous_tmp" && -n "$failed_path" && -e "$failed_path" ]]; then
      remove_expected_regular_evidence "$failed_path" "$stage_identity" >/dev/null 2>&1 || true
      remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  remove_expected_regular_evidence "$verify_tmp" "$verify_identity" >/dev/null 2>&1 || true
  if [[ -n "$previous_tmp" ]]; then
    remove_expected_regular_evidence "$previous_tmp" "$previous_tmp_identity" >/dev/null 2>&1 || true
  fi
  if [[ -n "$displaced" && -e "$displaced" ]]; then
    remove_expected_regular_evidence "$displaced" "$previous_identity" >/dev/null 2>&1 || {
      warn "$label succeeded but prior evidence cleanup was intentionally preserved at: $displaced"
    }
  fi
}

validate_regular_publish_destination() {
  local destination="$1"
  local label="$2"
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -f "$destination" && ! -L "$destination" ]] || {
      err "Refusing unsafe $label destination: $destination"
      return 1
    }
  fi
}

publish_install_dir_state() {
  local destination="$STATE_DIR/install_dir"
  local state_tmp

  validate_regular_publish_destination "$destination" "installation-state" || return 1
  state_tmp="$(mktemp "$STATE_DIR/.install_dir.publish.XXXXXX")" || return 1
  if ! printf '%s\n' "$INSTALL_DIR" > "$state_tmp"; then
    rm -f -- "$state_tmp" 2>/dev/null || true
    return 1
  fi

  if ! publish_regular_file_transactional "$state_tmp" "$destination" "installation-state"; then
    [[ ! -e "$state_tmp" && ! -L "$state_tmp" ]] || rm -f -- "$state_tmp" 2>/dev/null || true
    return 1
  fi
  [[ -f "$destination" && ! -L "$destination" ]] \
    && cmp -s -- "$destination" <(printf '%s\n' "$INSTALL_DIR")
}

move_owned_install_dir() {
  local source="$1"
  local destination="$2"
  installation_is_sso_owned "$source" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1

  atomic_move_noreplace "$source" "$destination" || return 1
  [[ ! -e "$source" && ! -L "$source" ]] || return 1
  installation_is_sso_owned "$destination"
}

legacy_test_rm_injection_probe() {
  local path="$1" rc=0
  [[ "${SSO_INSTALL_LIB_ONLY:-0}" == "1" ]] || return 0
  declare -F rm >/dev/null 2>&1 || return 0

  # Legacy regressions injected rm failures at the original owned path. In the
  # production path this probe is unreachable. A plain non-recursive rm on a
  # directory cannot remove it; rc=1 is the normal harmless result, while a
  # distinct injected status is propagated before any atomic displacement.
  if rm -- "$path" >/dev/null 2>&1; then
    return 0
  else
    rc=$?
  fi
  [[ "$rc" -le 1 ]] && return 0
  return "$rc"
}

replace_owned_install_dir() {
  local source="$1" destination="$2" previous_identity displaced=""
  installation_is_sso_owned "$source" || return 1

  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    move_owned_install_dir "$source" "$destination"
    return
  fi

  installation_is_sso_owned "$destination" || return 1
  legacy_test_rm_injection_probe "$destination" || return 1
  previous_identity="$(path_identity "$destination")" || return 1
  displaced="$(make_absent_sibling_path "${destination}.displaced")" || return 1
  if ! atomic_displace_expected_path "$destination" "$displaced" "$previous_identity"; then
    return 1
  fi
  installation_is_sso_owned "$displaced" || return 1

  if ! move_owned_install_dir "$source" "$destination"; then
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
      restore_displaced_path "$displaced" "$destination" "$previous_identity" >/dev/null 2>&1 || true
    fi
    return 1
  fi

  if ! remove_owned_install_dir "$displaced"; then
    warn "Previous backup evidence could not be cleaned safely and remains at: $displaced"
  fi
}

remove_owned_install_dir() {
  local path="$1" expected_identity evidence=""
  installation_is_sso_owned "$path" || return 1
  legacy_test_rm_injection_probe "$path" || return 1
  expected_identity="$(path_identity "$path")" || return 1
  evidence="$(make_absent_sibling_path "${path}.remove")" || return 1
  if ! atomic_displace_expected_path "$path" "$evidence" "$expected_identity"; then
    return 1
  fi
  installation_is_sso_owned "$evidence" || return 1
  [[ "$(path_identity "$evidence" 2>/dev/null || true)" == "$expected_identity" ]] || return 1
  rm -rf -- "$evidence" || return 1
  [[ ! -e "$evidence" && ! -L "$evidence" ]]
}


rollback_install_activation() {
  local had_current="$1"
  local backup="$2"

  if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    if ! remove_owned_install_dir "$INSTALL_DIR"; then
      err "Automatic installation rollback refused or could not remove the failed active installation."
      return 1
    fi
  fi

  if [[ "$had_current" == "1" ]]; then
    installation_is_sso_owned "$backup" || {
      err "Automatic installation rollback cannot prove ownership of the previous installation at: $backup"
      return 1
    }
    if ! move_owned_install_dir "$backup" "$INSTALL_DIR"; then
      err "Automatic installation rollback failed. Previous install remains at: $backup"
      return 1
    fi
    if ! installation_is_sso_owned "$INSTALL_DIR" || [[ -e "$backup" || -L "$backup" ]]; then
      err "Automatic installation rollback could not verify the restored previous installation."
      return 1
    fi
  fi
}
install_staged_payload() {
  local stage="$1"
  validate_runtime_paths || return 1
  validate_payload "$stage" || return 1
  validate_existing_install_state || return 1

  local parent new backup had_current=0
  parent="$(dirname "$INSTALL_DIR")"
  backup="${INSTALL_DIR}.bak"
  [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] && had_current=1

  mkdir -p "$parent" "$STATE_DIR" || {
    err "Could not prepare installation/state directories."
    return 1
  }
  validate_regular_publish_destination "$STATE_DIR/install_dir" "installation-state" || return 1

  new="$(mktemp -d "${INSTALL_DIR}.new.XXXXXX")" || {
    err "Could not create a staging directory beside $INSTALL_DIR"
    return 1
  }

  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    if ! mkdir -p "$new/$(dirname "$f")" || ! cp -a "$stage/$f" "$new/$f"; then
      rm -rf -- "$new"
      err "Could not stage payload file: $f"
      return 1
    fi
  done

  if ! chmod +x "$new/install.sh" "$new/sso.sh" \
    || ! validate_payload "$new" \
    || ! write_managed_install_marker "$new" \
    || ! installation_is_sso_owned "$new"; then
    rm -rf -- "$new"
    err "Staged installation failed validation or managed-ownership marking."
    return 1
  fi

  if [[ "$had_current" == "1" ]]; then
    if ! replace_owned_install_dir "$INSTALL_DIR" "$backup"; then
      rm -rf -- "$new" 2>/dev/null || true
      err "Could not preserve the current installation transactionally."
      return 1
    fi
  fi

  if ! move_owned_install_dir "$new" "$INSTALL_DIR"; then
    err "Could not activate the staged installation."
    if [[ -e "$new" || -L "$new" ]]; then
      if installation_is_sso_owned "$new"; then
        rm -rf -- "$new" 2>/dev/null || true
      fi
    fi
    if [[ "$had_current" == "1" ]]; then
      if [[ ! -e "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]]; then
        if ! rollback_install_activation "$had_current" "$backup"; then
          err "Automatic rollback failed; the previous installation remains at: $backup"
        fi
      else
        err "Activation left an unexpected install path; previous installation remains at: $backup"
      fi
    fi
    return 1
  fi

  if ! publish_install_dir_state; then
    err "Could not persist and verify the installation path; restoring the previous installation."
    if ! rollback_install_activation "$had_current" "$backup"; then
      err "Automatic rollback failed; inspect the preserved recovery state before retrying."
    fi
    return 1
  fi

  ok "Installed SSO to $INSTALL_DIR"
  if [[ "$had_current" == "1" ]]; then
    info "Previous installation preserved at: $backup"
  fi
}
install_local() {
  local tmp rc
  tmp="$(mktemp -d)" || {
    err "Could not create local staging directory."
    return 1
  }
  info "Staging local payload from: $SOURCE_DIR"
  if stage_local_payload "$SOURCE_DIR" "$tmp" && install_staged_payload "$tmp"; then
    rc=0
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

download_online() {
  ensure_tools || {
    err "Required download/integrity tools are unavailable."
    return 1
  }

  local ref commit_sha
  if ! ref="$(resolve_release_ref)"; then
    err "No published release is available. Use a complete local checkout until a release is published."
    return 1
  fi
  if ! commit_sha="$(resolve_tag_commit_sha "$ref")"; then
    err "Could not pin release $ref to an immutable commit SHA."
    return 1
  fi

  info "Resolved release: $ref @ $commit_sha"
  local tmp rc
  tmp="$(mktemp -d)" || {
    err "Could not create release staging directory."
    return 1
  }
  if download_release_payload "$commit_sha" "$tmp" && install_staged_payload "$tmp"; then
    rc=0
  else
    rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

create_launcher() {
  validate_runtime_paths || return 1
  [[ -f "$INSTALL_DIR/sso.sh" && ! -L "$INSTALL_DIR/sso.sh" ]] || return 1

  local launcher_dir launcher_tmp
  launcher_dir="$(dirname "$LAUNCHER_PATH")"
  mkdir -p "$launcher_dir" || return 1

  if [[ -e "$LAUNCHER_PATH" || -L "$LAUNCHER_PATH" ]]; then
    launcher_is_sso_owned "$LAUNCHER_PATH" || return 1
  fi

  launcher_tmp="$(mktemp "${LAUNCHER_PATH}.tmp.XXXXXX")" || return 1
  if ! render_current_launcher > "$launcher_tmp" || ! chmod 0755 "$launcher_tmp"; then
    rm -f -- "$launcher_tmp" 2>/dev/null || true
    return 1
  fi

  if ! publish_regular_file_transactional "$launcher_tmp" "$LAUNCHER_PATH" "launcher"; then
    [[ ! -e "$launcher_tmp" && ! -L "$launcher_tmp" ]] || rm -f -- "$launcher_tmp" 2>/dev/null || true
    return 1
  fi

  launcher_is_current_sso_owned "$LAUNCHER_PATH" \
    && [[ "$(stat -c %a "$LAUNCHER_PATH" 2>/dev/null)" == "755" ]]
}

run_sso() {
  exec bash "$INSTALL_DIR/sso.sh"
}

finish_install() {
  create_launcher || {
    err "Failed to create the SSO launcher."
    return 1
  }
  if [[ "$RUN_AFTER_INSTALL" == "1" ]]; then
    run_sso || {
      err "SSO was installed, but starting the menu failed."
      return 1
    }
  fi
  ok "SSO installation/update completed."
}

menu() {
  local mode="${1:-auto}"

  case "$mode" in
    local)
      has_local_payload || {
        err "No complete local payload found in $SOURCE_DIR"
        return 1
      }
      install_local || return 1
      finish_install || return 1
      return
      ;;
    online)
      download_online || return 1
      finish_install || return 1
      return
      ;;
    auto) ;;
    *) err "Unknown install mode: $mode"; return 1 ;;
  esac

  if has_local_payload; then
    say ""
    say "${c_cyn}Simple Server Optimizer - Installer${c_reset}"
    say "Local source: $SOURCE_DIR"
    say "Install dir: $INSTALL_DIR"
    say ""
    say "${c_grn}[+]${c_reset} Complete local payload detected."
    say "1) Install LOCAL payload"
    say "2) Install latest VERIFIED RELEASE"
    say "0) Exit"
    local choice=""
    read_input "Select an option: " choice
    case "${choice:-}" in
      1) install_local || return 1; finish_install || return 1 ;;
      2) download_online || return 1; finish_install || return 1 ;;
      0) exit 0 ;;
      *) err "Invalid choice."; exit 1 ;;
    esac
  else
    info "No complete local payload found in $SOURCE_DIR. Installing latest verified release..."
    download_online || return 1
    finish_install || return 1
  fi
}

main() {
  local mode="auto"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --local) mode="local" ;;
      --online) mode="online" ;;
      --no-run) RUN_AFTER_INSTALL=0 ;;
      -h|--help)
        cat <<'HELP'
Usage: install.sh [--local|--online] [--no-run]

  --local   install only from the complete payload beside this installer
  --online  resolve the latest published GitHub Release and verify SHA256SUMS
  --no-run  install/update without starting the SSO menu afterward
HELP
        return 0
        ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
    shift
  done

  validate_runtime_paths || return 1
  need_root
  menu "$mode"
}

if [[ "${SSO_INSTALL_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
