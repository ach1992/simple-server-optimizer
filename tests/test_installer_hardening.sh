#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

make_installed_payload() {
  local root="$1"
  local f
  for f in \
    install.sh sso.sh \
    modules/utils.sh modules/network.sh modules/cpu_irq.sh modules/firewall.sh \
    modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh \
    assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4; do
    mkdir -p "$root/$(dirname "$f")"
    cp -a "$ROOT_DIR/$f" "$root/$f"
  done
}

test_runtime_paths_are_canonical_and_persistence_is_independent() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    validate_runtime_paths

    local bad
    for bad in '/root/' '/root/.' '/tmp/../root' '//root/simple-server-optimizer' '/opt/sso/../sso'; do
      INSTALL_DIR="$bad"
      STATE_DIR="$tmp/state"
      LAUNCHER_PATH="$tmp/bin/sso"
      if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
    done

    INSTALL_DIR="$tmp/install"
    STATE_DIR='/etc'
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/install/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    STATE_DIR="$tmp/install.bak/state"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    STATE_DIR="$tmp/state"
    INSTALL_DIR="$tmp/state/install"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/install/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    LAUNCHER_PATH="$tmp/install.bak/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    mkdir -p "$tmp/real-install"
    ln -s "$tmp/real-install" "$tmp/install-link"
    INSTALL_DIR="$tmp/install-link"
    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi

    rm -f "$tmp/install-link"
    INSTALL_DIR="$tmp/install-file"
    printf 'not-a-directory\n' > "$INSTALL_DIR"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
    rm -f "$INSTALL_DIR"

    INSTALL_DIR="$tmp/install"
    STATE_DIR="$tmp/state-file"
    printf 'not-a-directory\n' > "$STATE_DIR"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
    rm -f "$STATE_DIR"

    STATE_DIR="$tmp/state"
    LAUNCHER_PATH="$tmp/bin/sso"
    mkdir -p "$LAUNCHER_PATH"
    if validate_runtime_paths >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_finish_install_only_runs_after_success() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"

    SOURCE_DIR="$tmp/source"
    has_local_payload() { return 0; }
    install_local() { return 42; }
    download_online() { return 43; }
    finish_install() { : > "$tmp/FINISHED"; return 0; }
    read_input() { local -n out="$2"; out=1; }
    say() { :; }
    info() { :; }
    err() { :; }

    if menu local; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    if menu online; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    if menu auto; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    has_local_payload() { return 1; }
    if menu auto; then exit 1; fi
    [[ ! -e "$tmp/FINISHED" ]]

    install_local() { return 0; }
    has_local_payload() { return 0; }
    menu local
    [[ -f "$tmp/FINISHED" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_payload_and_manifest_reject_symlinks() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"

    local payload="$tmp/payload" f
    for f in "${PAYLOAD_FILES[@]}"; do
      mkdir -p "$payload/$(dirname "$f")"
      printf 'payload\n' > "$payload/$f"
    done
    printf 'external\n' > "$tmp/external"
    rm -f "$payload/install.sh"
    ln -s "$tmp/external" "$payload/install.sh"
    if has_payload "$payload"; then exit 1; fi

    mkdir -p "$payload/release"
    printf '%064d  install.sh\n' 0 > "$tmp/manifest"
    ln -s "$tmp/manifest" "$payload/release/SHA256SUMS"
    if verify_release_manifest "$payload" >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_failed_curl_cannot_succeed_with_partial_output() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }
    curl() {
      printf 'partial-but-nonempty\n' > "$tmp/out"
      return 22
    }
    if curl_fetch 'https://example.invalid/payload' "$tmp/out"; then exit 1; fi
    [[ ! -e "$tmp/out" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_activation_failure_restores_previous_installation() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  printf 'previous\n' > "$tmp/install/PREVIOUS"
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }
    info() { :; }
    ok() { :; }
    mv() {
      local src dst
      if [[ "${1:-}" == "--" ]]; then
        src="${2:-}"
        dst="${3:-}"
      else
        src="${1:-}"
        dst="${2:-}"
      fi
      if [[ "$src" == "$INSTALL_DIR".new.* && "$dst" == "$INSTALL_DIR" && ! -e "$tmp/ACTIVATION_FAILED" ]]; then
        : > "$tmp/ACTIVATION_FAILED"
        return 73
      fi
      command mv "$@"
    }

    if install_staged_payload "$ROOT_DIR"; then exit 1; fi
    [[ -f "$tmp/ACTIVATION_FAILED" ]]
    [[ -f "$INSTALL_DIR/PREVIOUS" ]]
    [[ ! -e "$INSTALL_DIR.bak" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_rollback_removal_failure_preserves_previous_backup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/install.bak"
  printf 'failed-new\n' > "$tmp/install/NEW"
  printf 'previous\n' > "$tmp/install.bak/PREVIOUS"
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }
    rm() {
      local arg
      for arg in "$@"; do
        if [[ "$arg" == "$INSTALL_DIR" ]]; then return 74; fi
      done
      command rm "$@"
    }

    if rollback_install_activation 1 "$INSTALL_DIR.bak"; then exit 1; fi
    [[ -f "$INSTALL_DIR/NEW" ]]
    [[ -f "$INSTALL_DIR.bak/PREVIOUS" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_finish_install_propagates_run_failure() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    RUN_AFTER_INSTALL=1
    create_launcher() { return 0; }
    run_sso() { return 75; }
    err() { :; }
    if finish_install >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_unrecognized_install_and_backup_are_preserved() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }

    mkdir -p "$INSTALL_DIR"
    printf 'operator-data\n' > "$INSTALL_DIR/KEEP"
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR/KEEP" && ! -e "$INSTALL_DIR.bak" ]]

    rm -rf "$INSTALL_DIR"
    make_installed_payload "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR.bak"
    printf 'operator-backup\n' > "$INSTALL_DIR.bak/KEEP"
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR/sso.sh" && -f "$INSTALL_DIR.bak/KEEP" ]]

    rm -rf "$INSTALL_DIR"
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR.bak/KEEP" && ! -e "$INSTALL_DIR" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_online_trust_source_ignores_environment_redirects() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    export SSO_REPO_SLUG='attacker/example'
    export SSO_RELEASE_REF='v9.9.9'
    source "$ROOT_DIR/install.sh"
    [[ "$REPO_SLUG" == 'ach1992/simple-server-optimizer' ]]
    ensure_tools() { :; }
    curl() {
      local last="${!#}"
      [[ "$last" == 'https://github.com/ach1992/simple-server-optimizer/releases/latest' ]] || return 91
      printf 'https://github.com/ach1992/simple-server-optimizer/releases/tag/v1.1.0'
    }
    [[ "$(resolve_release_ref)" == 'v1.1.0' ]]
    curl() { printf 'https://evil.example/releases/tag/v1.1.0'; }
    if resolve_release_ref >/dev/null 2>&1; then exit 1; fi
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_production_paths_ignore_environment_redirects() {
  local out
  out="$(ROOT_DIR="$ROOT_DIR" \
    SSO_INSTALL_DIR='/tmp/attacker-install' \
    SSO_STATE_DIR='/tmp/attacker-state' \
    SSO_LAUNCHER_PATH='/tmp/attacker-launcher' \
    SSO_REPO_SLUG='attacker/example' \
    SSO_RELEASE_REF='v9.9.9' \
    bash -c 'source "$ROOT_DIR/install.sh" --help >/dev/null; printf "%s|%s|%s|%s" "$INSTALL_DIR" "$STATE_DIR" "$LAUNCHER_PATH" "$REPO_SLUG"')" || return 1
  [[ "$out" == '/root/simple-server-optimizer|/etc/sso|/usr/local/bin/sso|ach1992/simple-server-optimizer' ]]
}

generator_fixture() {
  local root="$1"
  local f
  mkdir -p "$root/scripts"
  cp -a "$ROOT_DIR/scripts/generate_release_manifest.sh" "$root/scripts/generate_release_manifest.sh"
  for f in \
    install.sh sso.sh \
    modules/utils.sh modules/network.sh modules/cpu_irq.sh modules/firewall.sh \
    modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh \
    assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4; do
    mkdir -p "$root/$(dirname "$f")"
    printf 'fixture:%s\n' "$f" > "$root/$f"
  done
}

test_manifest_generator_rejects_symlink_payload() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  generator_fixture "$tmp/repo"
  printf 'external\n' > "$tmp/external"
  rm -f "$tmp/repo/install.sh"
  ln -s "$tmp/external" "$tmp/repo/install.sh"
  if "$tmp/repo/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  [[ ! -e "$tmp/repo/release/SHA256SUMS" ]]
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_manifest_generator_failure_preserves_previous_manifest() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  generator_fixture "$tmp/repo"
  mkdir -p "$tmp/repo/release" "$tmp/bin"
  printf 'previous-manifest\n' > "$tmp/repo/release/SHA256SUMS"
  cat > "$tmp/bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
printf 'partial-output\n'
exit 76
MOCK
  chmod +x "$tmp/bin/sha256sum"
  if PATH="$tmp/bin:$PATH" "$tmp/repo/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  [[ "$(cat "$tmp/repo/release/SHA256SUMS")" == 'previous-manifest' ]]
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run_test "runtime paths are canonical and durable state/launcher stay outside replaceable trees" test_runtime_paths_are_canonical_and_persistence_is_independent
run_test "finish_install runs only after successful install/download" test_finish_install_only_runs_after_success
run_test "runtime payload and checksum manifest reject symlink metadata" test_payload_and_manifest_reject_symlinks
run_test "curl failure cannot be hidden by a partial nonempty output" test_failed_curl_cannot_succeed_with_partial_output
run_test "activation failure restores the previous installation" test_activation_failure_restores_previous_installation
run_test "rollback removal failure preserves the previous backup evidence" test_rollback_removal_failure_preserves_previous_backup
run_test "finish_install propagates a failed SSO launch" test_finish_install_propagates_run_failure
run_test "unrecognized install and recovery paths are preserved" test_unrecognized_install_and_backup_are_preserved
run_test "trusted online source ignores environment redirects" test_online_trust_source_ignores_environment_redirects
run_test "production runtime paths ignore environment redirects" test_production_paths_ignore_environment_redirects
run_test "manifest generator rejects symlinked runtime payload" test_manifest_generator_rejects_symlink_payload
run_test "manifest generation failure preserves the previous manifest" test_manifest_generator_failure_preserves_previous_manifest
finish_tests
