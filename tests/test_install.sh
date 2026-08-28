#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/testlib.sh"
source "$ROOT_DIR/install.sh"

make_payload() {
  local root="$1"
  mkdir -p "$root/modules" "$root/assets"
  cat > "$root/install.sh" <<'SH'
#!/usr/bin/env bash
true
SH
  cat > "$root/sso.sh" <<'SH'
#!/usr/bin/env bash
true
SH
  local f
  for f in utils.sh network.sh cpu_irq.sh firewall.sh fail2ban.sh rollback.sh uninstall.sh; do
    printf '#!/usr/bin/env bash\ntrue\n' > "$root/modules/$f"
  done
  printf '127.0.0.1\n' > "$root/assets/whitelist-default.ipv4"
}

configure_temp_paths() {
  local root="$1"
  INSTALL_DIR="$root/installed"
  STATE_DIR="$root/state"
  LAUNCHER_PATH="$root/bin/sso"
}

test_local_install_uses_source_and_first_install_has_no_backup() {
  local t
  t="$(mktemp -d)" || return 1
  make_payload "$t/source" || return 1
  configure_temp_paths "$t" || return 1
  SOURCE_DIR="$t/source"

  install_local || return 1
  [[ -f "$INSTALL_DIR/sso.sh" ]] || return 1
  [[ -f "$INSTALL_DIR/modules/firewall.sh" ]] || return 1
  [[ ! -e "$INSTALL_DIR.bak" ]] || return 1
  [[ "$(cat "$STATE_DIR/install_dir")" == "$INSTALL_DIR" ]] || return 1
  grep -Fq "$INSTALL_DIR/sso.sh" "$LAUNCHER_PATH" || return 1
  rm -rf "$t"
}

test_update_keeps_one_previous_install() {
  local t
  t="$(mktemp -d)" || return 1
  make_payload "$t/source1" || return 1
  make_payload "$t/source2" || return 1
  printf '# old\n' >> "$t/source1/sso.sh"
  printf '# new\n' >> "$t/source2/sso.sh"
  configure_temp_paths "$t" || return 1

  SOURCE_DIR="$t/source1"
  install_local || return 1
  mkdir -p "$INSTALL_DIR/backups" || return 1
  printf 'keep-me\n' > "$INSTALL_DIR/backups/existing"

  SOURCE_DIR="$t/source2"
  install_local || return 1

  [[ "$(cat "$INSTALL_DIR/backups/existing")" == "keep-me" ]] || return 1
  grep -q '# new' "$INSTALL_DIR/sso.sh" || return 1
  grep -q '# old' "$INSTALL_DIR.bak/sso.sh" || return 1
  rm -rf "$t"
}

test_incomplete_payload_does_not_touch_existing_install() {
  local t
  t="$(mktemp -d)" || return 1
  make_payload "$t/good" || return 1
  make_payload "$t/bad" || return 1
  rm -f "$t/bad/modules/firewall.sh"
  configure_temp_paths "$t" || return 1

  SOURCE_DIR="$t/good"
  install_local || return 1
  printf 'operator-marker\n' >> "$INSTALL_DIR/sso.sh"

  SOURCE_DIR="$t/bad"
  if install_local >/dev/null 2>&1; then
    return 1
  fi
  grep -q 'operator-marker' "$INSTALL_DIR/sso.sh" || return 1
  [[ ! -e "$INSTALL_DIR.bak" ]] || return 1
  rm -rf "$t"
}

test_online_download_uses_explicit_online_path() {
  local t remote
  t="$(mktemp -d)" || return 1
  remote="$t/remote"
  make_payload "$remote" || return 1
  configure_temp_paths "$t" || return 1

  curl() {
    local url="" out="" arg
    while [[ "$#" -gt 0 ]]; do
      arg="$1"
      shift
      case "$arg" in
        http*) url="$arg" ;;
        -o) out="$1"; shift ;;
      esac
    done
    [[ -n "$url" && -n "$out" ]] || return 1
    local rel
    rel="${url#https://raw.githubusercontent.com/${REPO_SLUG}/${RELEASE_REF}/}"
    [[ -f "$remote/$rel" ]] || return 22
    cp -a "$remote/$rel" "$out"
  }

  download_online || return 1
  [[ -f "$INSTALL_DIR/sso.sh" ]] || return 1
  [[ ! -e "$INSTALL_DIR.bak" ]] || return 1
  rm -rf "$t"
}

test_update_menu_uses_installed_installer_explicitly() {
  grep -Fq 'bash "$SSO_DIR/install.sh" --online --no-run' "$ROOT_DIR/sso.sh" || return 1
  if grep -Fq 'raw.githubusercontent.com' "$ROOT_DIR/sso.sh"; then
    return 1
  fi
}

run_test "local install uses source directory and first install has no backup" test_local_install_uses_source_and_first_install_has_no_backup
run_test "explicit update keeps one previous install" test_update_keeps_one_previous_install
run_test "incomplete payload leaves existing install untouched" test_incomplete_payload_does_not_touch_existing_install
run_test "online mode downloads then installs through the same simple path" test_online_download_uses_explicit_online_path
run_test "update menu uses installed installer with explicit online mode" test_update_menu_uses_installed_installer_explicitly
finish_tests
