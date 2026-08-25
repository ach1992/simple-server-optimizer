#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

make_payload() {
  local target="$1"
  mkdir -p "$target/modules" "$target/assets"
  cp -a "$ROOT_DIR/install.sh" "$target/install.sh"
  cp -a "$ROOT_DIR/sso.sh" "$target/sso.sh"
  cp -a "$ROOT_DIR/modules/." "$target/modules/"
  cp -a "$ROOT_DIR/assets/whitelist-default.ipv4" "$target/assets/whitelist-default.ipv4"
  cp -a "$ROOT_DIR/assets/blocklist-ip.ipv4" "$target/assets/blocklist-ip.ipv4"
}

make_manifest() {
  local payload="$1"
  mkdir -p "$payload/release"
  (
    cd "$payload" || exit 1
    sha256sum install.sh sso.sh modules/utils.sh modules/network.sh modules/cpu_irq.sh \
      modules/firewall.sh modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh \
      assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4 > release/SHA256SUMS
  )
}

test_local_payload_uses_source_directory() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local payload="$tmp/source"
  make_payload "$payload"

  ROOT_DIR="$ROOT_DIR" PAYLOAD="$payload" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    SOURCE_DIR="$PAYLOAD"
    has_local_payload
    install_local
    [[ -f "$SSO_INSTALL_DIR/sso.sh" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_first_install_does_not_create_backup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local payload="$tmp/payload"
  make_payload "$payload"

  ROOT_DIR="$ROOT_DIR" PAYLOAD="$payload" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    install_staged_payload "$PAYLOAD"
    [[ -d "$SSO_INSTALL_DIR" ]]
    [[ ! -e "$SSO_INSTALL_DIR.bak" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_update_preserves_previous_installation() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local payload="$tmp/payload"
  make_payload "$payload"
  mkdir -p "$tmp/install"
  printf 'previous\n' > "$tmp/install/PREVIOUS"

  ROOT_DIR="$ROOT_DIR" PAYLOAD="$payload" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    install_staged_payload "$PAYLOAD"
    [[ -f "$SSO_INSTALL_DIR/sso.sh" ]]
    [[ -f "$SSO_INSTALL_DIR.bak/PREVIOUS" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_manifest_rejects_checksum_corruption() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local payload="$tmp/payload"
  make_payload "$payload"
  make_manifest "$payload"
  printf '\n# corruption\n' >> "$payload/sso.sh"

  ROOT_DIR="$ROOT_DIR" PAYLOAD="$payload" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    ! verify_release_manifest "$PAYLOAD"
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_manifest_requires_exact_payload_file_set() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local payload="$tmp/payload"
  make_payload "$payload"
  make_manifest "$payload"
  grep -v 'assets/blocklist-ip.ipv4' "$payload/release/SHA256SUMS" > "$payload/release/SHA256SUMS.tmp"
  mv "$payload/release/SHA256SUMS.tmp" "$payload/release/SHA256SUMS"

  ROOT_DIR="$ROOT_DIR" PAYLOAD="$payload" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    ! verify_release_manifest "$PAYLOAD"
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_invalid_online_payload_keeps_live_installation() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local fixture="$tmp/release-fixture"
  make_payload "$fixture"
  make_manifest "$fixture"
  printf '\n# corrupted after manifest\n' >> "$fixture/sso.sh"
  mkdir -p "$tmp/install"
  printf 'keep-me\n' > "$tmp/install/LIVE"

  ROOT_DIR="$ROOT_DIR" FIXTURE="$fixture" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    ensure_tools() { :; }
    resolve_release_ref() { printf "v1.1.0\n"; }
    resolve_tag_commit_sha() { printf "1111111111111111111111111111111111111111\n"; }
    curl_fetch() {
      local url="$1" out="$2"
      local rel="${url#*1111111111111111111111111111111111111111/}"
      cp -a "$FIXTURE/$rel" "$out"
    }
    ! download_online
    [[ -f "$SSO_INSTALL_DIR/LIVE" ]]
    [[ ! -e "$SSO_INSTALL_DIR.bak" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_valid_online_payload_is_verified_then_installed() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  local fixture="$tmp/release-fixture"
  make_payload "$fixture"
  make_manifest "$fixture"

  ROOT_DIR="$ROOT_DIR" FIXTURE="$fixture" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    ensure_tools() { :; }
    resolve_release_ref() { printf "v1.1.0\n"; }
    resolve_tag_commit_sha() { printf "1111111111111111111111111111111111111111\n"; }
    curl_fetch() {
      local url="$1" out="$2"
      local rel="${url#*1111111111111111111111111111111111111111/}"
      cp -a "$FIXTURE/$rel" "$out"
    }
    download_online
    [[ -f "$SSO_INSTALL_DIR/sso.sh" ]]
    [[ "$(cat "$SSO_STATE_DIR/install_dir")" == "$SSO_INSTALL_DIR" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_release_ref_must_be_semver_tag() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    validate_release_ref v1.1.0
    validate_release_ref v1.1.0-rc.1
    ! validate_release_ref main
    ! validate_release_ref feature/test
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_tag_resolution_pins_annotated_tag_to_commit() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    github_api_get() {
      case "$1" in
        */git/ref/tags/v1.1.0)
          printf '%s\n' '{"object":{"type":"tag","sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
          ;;
        */git/tags/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
          printf '%s\n' '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","object":{"type":"commit","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
          ;;
        *) return 1 ;;
      esac
    }
    [[ "$(resolve_tag_commit_sha v1.1.0)" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]]
  ) >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_unsafe_install_root_is_rejected() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="/"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    source "$ROOT_DIR/install.sh"
    ! validate_runtime_paths
  ) >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_no_run_mode_does_not_launch_nested_sso() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  mkdir -p "$tmp/install" "$tmp/state" "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/install/sso.sh"

  (
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$tmp/install"
    export SSO_STATE_DIR="$tmp/state"
    export SSO_LAUNCHER_PATH="$tmp/bin/sso"
    export SSO_INSTALL_RUN_SSO=0
    source "$ROOT_DIR/install.sh"
    run_sso() { printf 'launched\n' > "$tmp/LAUNCHED"; }
    finish_install
    [[ ! -e "$tmp/LAUNCHED" ]]
    [[ -x "$tmp/bin/sso" ]]
  ) >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_legacy_curl_retry_option_removed() {
  ! grep -q -- '--retry-all-errors' "$ROOT_DIR/install.sh"
}

test_manifest_generator_matches_payload_contract() {
  local manifest="$ROOT_DIR/release/SHA256SUMS"
  rm -f "$manifest"
  if ! "$ROOT_DIR/scripts/generate_release_manifest.sh" >/dev/null; then
    return 1
  fi

  local count
  count="$(wc -l < "$manifest" | tr -d ' ')"
  local rc=0
  [[ "$count" == "11" ]] || rc=1

  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    source "$ROOT_DIR/install.sh"
    verify_release_manifest "$ROOT_DIR"
  ' >/dev/null 2>&1 || rc=1

  rm -f "$manifest"
  return "$rc"
}

run_test "local install discovers payload from the actual source directory" test_local_payload_uses_source_directory
run_test "first install does not manufacture a .bak directory" test_first_install_does_not_create_backup
run_test "update preserves the prior installation as .bak" test_update_preserves_previous_installation
run_test "release checksum corruption is rejected" test_manifest_rejects_checksum_corruption
run_test "release manifest must describe the exact payload" test_manifest_requires_exact_payload_file_set
run_test "invalid online payload leaves the live installation untouched" test_invalid_online_payload_keeps_live_installation
run_test "valid online payload is verified before installation" test_valid_online_payload_is_verified_then_installed
run_test "online release refs must be SemVer tags, not mutable branches" test_release_ref_must_be_semver_tag
run_test "annotated release tag is pinned to its commit SHA" test_tag_resolution_pins_annotated_tag_to_commit
run_test "unsafe installation root is rejected before mutation" test_unsafe_install_root_is_rejected
run_test "--no-run completes without launching a nested SSO menu" test_no_run_mode_does_not_launch_nested_sso
run_test "installer avoids curl option unavailable on Debian 10" test_legacy_curl_retry_option_removed
run_test "release manifest generator matches installer payload contract" test_manifest_generator_matches_payload_contract
finish_tests
