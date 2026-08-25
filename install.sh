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

launcher_is_sso_owned() {
  local launcher="$1"
  [[ -f "$launcher" && ! -L "$launcher" ]] || return 1
  if grep -Fq '# Managed by Simple Server Optimizer.' "$launcher" 2>/dev/null; then
    return 0
  fi

  # Compatibility with the launcher emitted by the pre-v1.1.0 installer.
  grep -Fq 'INSTALL_DIR_FILE=' "$launcher" 2>/dev/null \
    && grep -Fq 'exec bash "${INSTALL_DIR}/sso.sh" "$@"' "$launcher" 2>/dev/null
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

has_payload() {
  local root="$1"
  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    [[ -f "$root/$f" && ! -L "$root/$f" && -s "$root/$f" ]] || return 1
  done
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
    [[ -d "$INSTALL_DIR" && ! -L "$INSTALL_DIR" ]] || return 1
    has_payload "$INSTALL_DIR" || {
      err "Refusing to replace an existing directory that is not a complete SSO installation: $INSTALL_DIR"
      return 1
    }
    has_current=1
  fi

  if [[ -e "$backup" || -L "$backup" ]]; then
    [[ "$has_current" == "1" ]] || {
      err "A recovery backup exists without a live SSO installation; recover or move it before reinstalling: $backup"
      return 1
    }
    [[ -d "$backup" && ! -L "$backup" ]] && has_payload "$backup" || {
      err "Refusing to delete or replace an unrecognized recovery path: $backup"
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

validate_release_ref() {
  local ref="$1"
  [[ "$ref" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
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

json_last_sha() {
  grep -Eo '"sha"[[:space:]]*:[[:space:]]*"[0-9a-f]{40}"' | tail -n1 | grep -Eo '[0-9a-f]{40}'
}

json_last_type() {
  grep -Eo '"type"[[:space:]]*:[[:space:]]*"(commit|tag)"' | tail -n1 | sed -E 's/.*"(commit|tag)"/\1/'
}

resolve_tag_commit_sha() {
  local ref="$1"
  validate_release_ref "$ref" || return 1

  local json type sha depth=0
  json="$(github_api_get "https://api.github.com/repos/${REPO_SLUG}/git/ref/tags/${ref}")" || return 1
  type="$(printf '%s\n' "$json" | json_last_type)"
  sha="$(printf '%s\n' "$json" | json_last_sha)"

  while [[ "$type" == "tag" && "$depth" -lt 5 ]]; do
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    json="$(github_api_get "https://api.github.com/repos/${REPO_SLUG}/git/tags/${sha}")" || return 1
    type="$(printf '%s\n' "$json" | json_last_type)"
    sha="$(printf '%s\n' "$json" | json_last_sha)"
    depth=$((depth + 1))
  done

  [[ "$type" == "commit" && "$sha" =~ ^[0-9a-f]{40}$ ]] || {
    err "Release tag did not resolve to a commit SHA."
    return 1
  }
  printf '%s\n' "$sha"
}

verify_release_manifest() {
  local root="$1"
  local manifest="$root/release/SHA256SUMS"
  [[ -f "$manifest" && ! -L "$manifest" && -s "$manifest" ]] || {
    err "Release checksum manifest is missing or not a regular file."
    return 1
  }

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
    $1 !~ /^[0-9a-fA-F]{64}$/ { exit 3 }
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

rollback_install_activation() {
  local had_current="$1"
  local backup="$2"

  if ! rm -rf -- "$INSTALL_DIR" || [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    err "Automatic installation rollback could not remove the failed active installation."
    return 1
  fi

  if [[ "$had_current" == "1" ]]; then
    [[ -d "$backup" && ! -L "$backup" ]] || {
      err "Automatic installation rollback cannot find a trustworthy previous installation at: $backup"
      return 1
    }
    if ! mv -- "$backup" "$INSTALL_DIR"; then
      err "Automatic installation rollback failed. Previous install remains at: $backup"
      return 1
    fi
    if [[ ! -d "$INSTALL_DIR" || -L "$INSTALL_DIR" || -e "$backup" || -L "$backup" ]]; then
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
  [[ -d "$INSTALL_DIR" ]] && had_current=1

  mkdir -p "$parent" "$STATE_DIR" || {
    err "Could not prepare installation/state directories."
    return 1
  }
  new="$(mktemp -d "${INSTALL_DIR}.new.XXXXXX")" || {
    err "Could not create a staging directory beside $INSTALL_DIR"
    return 1
  }

  local f
  for f in "${PAYLOAD_FILES[@]}"; do
    if ! mkdir -p "$new/$(dirname "$f")" || ! cp -a "$stage/$f" "$new/$f"; then
      rm -rf "$new"
      err "Could not stage payload file: $f"
      return 1
    fi
  done

  if ! chmod +x "$new/install.sh" "$new/sso.sh" || ! validate_payload "$new"; then
    rm -rf "$new"
    err "Staged installation failed validation."
    return 1
  fi

  if [[ "$had_current" == "1" ]]; then
    if ! rm -rf -- "$backup" || [[ -e "$backup" || -L "$backup" ]]; then
      rm -rf -- "$new" 2>/dev/null || true
      err "Could not rotate the previous installation backup."
      return 1
    fi
    if ! mv -- "$INSTALL_DIR" "$backup"; then
      rm -rf -- "$new" 2>/dev/null || true
      err "Could not preserve the current installation."
      return 1
    fi
  fi

  if ! mv -- "$new" "$INSTALL_DIR"; then
    err "Could not activate the staged installation."
    rm -rf "$new" 2>/dev/null || true
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

  local state_tmp
  if ! state_tmp="$(mktemp "$STATE_DIR/.install_dir.XXXXXX")"; then
    err "Could not create installation-state staging file; restoring the previous installation."
    if ! rollback_install_activation "$had_current" "$backup"; then
      err "Automatic rollback failed; inspect the preserved recovery state before retrying."
    fi
    return 1
  fi
  if ! printf '%s\n' "$INSTALL_DIR" > "$state_tmp" || ! mv -f "$state_tmp" "$STATE_DIR/install_dir"; then
    rm -f "$state_tmp"
    err "Could not persist the installation path; restoring the previous installation."
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
  [[ -f "$INSTALL_DIR/sso.sh" ]] || return 1

  local launcher_dir launcher_tmp state_file_quoted fallback_install_quoted
  launcher_dir="$(dirname "$LAUNCHER_PATH")"
  mkdir -p "$launcher_dir" || return 1
  launcher_tmp="$(mktemp "${LAUNCHER_PATH}.tmp.XXXXXX")" || return 1

  printf -v state_file_quoted '%q' "$STATE_DIR/install_dir"
  printf -v fallback_install_quoted '%q' "$INSTALL_DIR"

  if ! cat > "$launcher_tmp" <<LAUNCHER_SCRIPT
#!/usr/bin/env bash
# Managed by Simple Server Optimizer.
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
  then
    rm -f "$launcher_tmp"
    return 1
  fi

  if ! chmod 0755 "$launcher_tmp" || ! mv -f "$launcher_tmp" "$LAUNCHER_PATH"; then
    rm -f "$launcher_tmp"
    return 1
  fi
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
