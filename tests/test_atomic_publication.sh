#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0

run_case() {
  local name="$1" fn="$2" rc had_errexit=0
  case $- in *e*) had_errexit=1 ;; esac
  set +e
  (
    set -e
    "$fn"
  )
  rc=$?
  if [[ "$had_errexit" == "1" ]]; then set -e; else set +e; fi
  if [[ "$rc" -eq 0 ]]; then
    printf 'ok - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    return 1
  fi
}

load_installer() {
  local root="$1"
  export SSO_INSTALL_LIB_ONLY=1
  export SSO_INSTALL_DIR="$root/install"
  export SSO_STATE_DIR="$root/state"
  export SSO_LAUNCHER_PATH="$root/bin/sso"
  # shellcheck source=install.sh
  source "$ROOT_DIR/install.sh"
  err(){ :; }
  warn(){ :; }
  info(){ :; }
  ok(){ :; }
}

synthetic_intermediate_failure() {
  false
  true
}

harness_intermediate_failure_is_detected() {
  local rc had_errexit=0
  case $- in *e*) had_errexit=1 ;; esac
  set +e
  (
    set -e
    synthetic_intermediate_failure
  )
  rc=$?
  if [[ "$had_errexit" == "1" ]]; then set -e; else set +e; fi
  [[ "$rc" -ne 0 ]]
}

atomic_existing_destination_is_untouched() {
  local t; t="$(mktemp -d)"
  load_installer "$t"
  printf source > "$t/source"
  printf operator > "$t/destination"
  if atomic_move_noreplace "$t/source" "$t/destination"; then return 1; fi
  [[ "$(cat "$t/source")" == source && "$(cat "$t/destination")" == operator ]]
}

atomic_real_race_is_untouched() {
  local t; t="$(mktemp -d)"
  load_installer "$t"
  printf source > "$t/source"
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local source="$1" destination="$2"
    printf operator > "$destination"
    real_rename_noreplace "$source" "$destination"
  }
  if atomic_move_noreplace "$t/source" "$t/destination"; then return 1; fi
  [[ "$(cat "$t/source")" == source && "$(cat "$t/destination")" == operator ]]
}

atomic_post_rename_replacement_is_untouched() {
  local t; t="$(mktemp -d)"
  load_installer "$t"
  printf source > "$t/source"
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local source="$1" destination="$2" replacement
    real_rename_noreplace "$source" "$destination" || return
    replacement="${destination}.operator.$$"
    printf operator > "$replacement"
    command mv -fT -- "$replacement" "$destination"
  }
  if atomic_move_noreplace "$t/source" "$t/destination"; then return 1; fi
  [[ ! -e "$t/source" && "$(cat "$t/destination")" == operator ]]
}

atomic_displace_post_rename_replacement_is_untouched() {
  local t expected evidence; t="$(mktemp -d)"
  load_installer "$t"
  printf owned > "$t/path"
  expected="$(path_identity "$t/path")"
  evidence="$t/evidence"
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local source="$1" destination="$2" replacement
    real_rename_noreplace "$source" "$destination" || return
    if [[ "$source" == "$t/path" && "$destination" == "$evidence" ]]; then
      replacement="${destination}.operator.$$"
      printf operator > "$replacement"
      command mv -fT -- "$replacement" "$destination"
    fi
  }
  if atomic_displace_expected_path "$t/path" "$evidence" "$expected"; then return 1; fi
  [[ ! -e "$t/path" && "$(cat "$evidence")" == operator ]]
}

staging_replacement_before_failure_cleanup_is_untouched() {
  local t operator_path; t="$(mktemp -d)"
  load_installer "$t"
  mkdir -p "$STATE_DIR"
  cp() {
    local destination="${@: -1}" newroot
    if [[ "$destination" == "$INSTALL_DIR.new."*/install.sh ]]; then
      newroot="${destination%/install.sh}"
      command mv -- "$newroot" "${newroot}.owned-original"
      mkdir "$newroot"
      printf operator > "$newroot/OPERATOR"
      printf '%s\n' "$newroot" > "$t/operator-path"
      return 82
    fi
    command cp "$@"
  }
  if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then return 1; fi
  operator_path="$(cat "$t/operator-path")"
  [[ -d "$operator_path" && "$(cat "$operator_path/OPERATOR")" == operator ]]
}

direct_installer_ignores_inherited_test_mode() {
  local output
  output="$(SSO_INSTALL_LIB_ONLY=1 SSO_INSTALL_DIR=/tmp/hostile-install SSO_STATE_DIR=/tmp/hostile-state SSO_LAUNCHER_PATH=/tmp/hostile-sso bash "$ROOT_DIR/install.sh" --help)"
  grep -q '^Usage: install.sh' <<<"$output"
}

state_publication_real_race_preserves_both_sides() {
  local t; t="$(mktemp -d)"
  load_installer "$t"
  mkdir -p "$STATE_DIR"
  printf old > "$STATE_DIR/install_dir"
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local source="$1" destination="$2"
    if [[ "$source" == "$STATE_DIR/.install_dir.publish."* && "$destination" == "$STATE_DIR/install_dir" ]]; then
      printf operator > "$destination"
    fi
    real_rename_noreplace "$source" "$destination"
  }
  if publish_install_dir_state >/dev/null 2>&1; then return 1; fi
  [[ "$(cat "$STATE_DIR/install_dir")" == operator ]]
  compgen -G "$STATE_DIR/.install_dir.previous.*" >/dev/null
}

launcher_publication_real_race_preserves_operator_file() {
  local t; t="$(mktemp -d)"
  load_installer "$t"
  mkdir -p "$INSTALL_DIR" "$STATE_DIR" "$(dirname "$LAUNCHER_PATH")"
  printf '#!/usr/bin/env bash\n' > "$INSTALL_DIR/sso.sh"
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local source="$1" destination="$2"
    if [[ "$source" == "$LAUNCHER_PATH.tmp."* && "$destination" == "$LAUNCHER_PATH" ]]; then
      printf operator > "$destination"
    fi
    real_rename_noreplace "$source" "$destination"
  }
  if create_launcher >/dev/null 2>&1; then return 1; fi
  [[ "$(cat "$LAUNCHER_PATH")" == operator ]]
}

backup_rotation_real_race_preserves_operator_destination() {
  local t source destination; t="$(mktemp -d)"
  load_installer "$t"
  source="$t/current"; destination="$t/current.bak"
  mkdir "$source" "$destination"; touch "$source/OWNED" "$destination/OWNED"; printf old > "$destination/OLD"
  installation_is_sso_owned(){ [[ -d "$1" && -f "$1/OWNED" ]]; }
  eval "$(declare -f rename_noreplace | sed '1s/rename_noreplace/real_rename_noreplace/')"
  rename_noreplace() {
    local src="$1" dst="$2"
    if [[ "$src" == "$source" && "$dst" == "$destination" ]]; then
      mkdir -p "$destination"; printf operator > "$destination/OPERATOR"
    fi
    real_rename_noreplace "$src" "$dst"
  }
  if replace_owned_install_dir "$source" "$destination" >/dev/null 2>&1; then return 1; fi
  [[ -f "$destination/OPERATOR" && -d "$source" ]]
  compgen -G "$destination.displaced.*" >/dev/null
}

make_manifest_fixture() {
  local root="$1" f
  mkdir -p "$root/scripts"
  cp "$ROOT_DIR/scripts/generate_release_manifest.sh" "$root/scripts/generate_release_manifest.sh"
  chmod +x "$root/scripts/generate_release_manifest.sh"
  for f in install.sh sso.sh modules/utils.sh modules/network.sh modules/cpu_irq.sh modules/firewall.sh modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4; do
    mkdir -p "$root/$(dirname "$f")"
    printf 'fixture:%s\n' "$f" > "$root/$f"
  done
}

manifest_previous_copy_corrupt_success_is_rejected() {
  local t before; t="$(mktemp -d)"
  make_manifest_fixture "$t/repo"
  "$t/repo/scripts/generate_release_manifest.sh" >/dev/null
  before="$(cat "$t/repo/release/SHA256SUMS")"
  mkdir "$t/bin"
  cat > "$t/bin/cp" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
/usr/bin/cp "$@"
destination="${@: -1}"
if [[ "$destination" == *'.SHA256SUMS.previous.'* ]]; then printf 'corrupt-copy\n' > "$destination"; fi
MOCK
  chmod +x "$t/bin/cp"
  if PATH="$t/bin:$PATH" "$t/repo/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then return 1; fi
  [[ "$(cat "$t/repo/release/SHA256SUMS")" == "$before" ]]
}

manifest_real_race_preserves_operator_destination() {
  local t real_python; t="$(mktemp -d)"; real_python="$(command -v python3)"
  make_manifest_fixture "$t/repo"; mkdir "$t/bin"
  cat > "$t/bin/python3" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
source_path="\${2:-}"; destination="\${3:-}"
if [[ "\$source_path" == *'.SHA256SUMS.publish.'* && "\$destination" == 'release/SHA256SUMS' ]]; then printf 'operator-race\n' > "\$destination"; fi
exec "$real_python" "\$@"
MOCK
  chmod +x "$t/bin/python3"
  if (cd "$t/repo" && PATH="$t/bin:$PATH" scripts/generate_release_manifest.sh >/dev/null 2>&1); then return 1; fi
  [[ "$(cat "$t/repo/release/SHA256SUMS")" == operator-race ]]
}

manifest_displace_post_rename_replacement_is_untouched() {
  local t real_python displaced; t="$(mktemp -d)"; real_python="$(command -v python3)"
  make_manifest_fixture "$t/repo"
  "$t/repo/scripts/generate_release_manifest.sh" >/dev/null
  printf 'changed\n' >> "$t/repo/install.sh"
  mkdir "$t/bin"
  cat > "$t/bin/python3" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
source_path="\${2:-}"; destination="\${3:-}"
if [[ "\$source_path" == 'release/SHA256SUMS' && "\$destination" == release/.SHA256SUMS.displaced.* ]]; then
  "$real_python" "\$@"
  replacement="release/.operator-evidence.\$\$"
  printf 'operator-evidence\n' > "\$replacement"
  /usr/bin/mv -fT -- "\$replacement" "\$destination"
  exit 0
fi
exec "$real_python" "\$@"
MOCK
  chmod +x "$t/bin/python3"
  if (cd "$t/repo" && PATH="$t/bin:$PATH" scripts/generate_release_manifest.sh >/dev/null 2>&1); then return 1; fi
  [[ ! -e "$t/repo/release/SHA256SUMS" ]]
  displaced="$(find "$t/repo/release" -maxdepth 1 -type f -name '.SHA256SUMS.displaced.*' -print -quit)"
  [[ -n "$displaced" && "$(cat "$displaced")" == operator-evidence ]]
}

direct_manifest_ignores_inherited_test_variables() {
  local t; t="$(mktemp -d)"
  make_manifest_fixture "$t/repo"
  mkdir "$t/bin"
  cat > "$t/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
: > "$MV_FLAG"
exec /usr/bin/mv "$@"
MOCK
  chmod +x "$t/bin/mv"
  (cd "$t/repo" && SSO_TEST_ONLY=1 MV_FLAG="$t/MV_CALLED" PATH="$t/bin:$PATH" scripts/generate_release_manifest.sh >/dev/null)
  [[ ! -e "$t/MV_CALLED" ]]
  [[ -s "$t/repo/release/SHA256SUMS" ]]
}

manifest_corrupt_recovery_preserves_original_previous_copy() {
  local t before output rc previous real_python
  t="$(mktemp -d)"; real_python="$(command -v python3)"
  make_manifest_fixture "$t/repo"; "$t/repo/scripts/generate_release_manifest.sh" >/dev/null
  before="$(cat "$t/repo/release/SHA256SUMS")"; printf 'changed\n' >> "$t/repo/install.sh"; mkdir "$t/bin"
  cat > "$t/bin/python3" <<MOCK
#!/usr/bin/env bash
set -Eeuo pipefail
source_path="\${2:-}"; destination="\${3:-}"
if [[ "\$destination" == 'release/SHA256SUMS' && "\$source_path" == *'.SHA256SUMS.publish.'* ]]; then
  "$real_python" "\$@"; printf 'corrupt-published\n' > "\$destination"; exit 0
fi
if [[ "\$destination" == 'release/SHA256SUMS' && "\$source_path" == *'.restore-SHA256SUMS.'* ]]; then
  "$real_python" "\$@"; printf 'corrupt-restored\n' > "\$destination"; exit 0
fi
exec "$real_python" "\$@"
MOCK
  chmod +x "$t/bin/python3"
  set +e; output="$(cd "$t/repo" && PATH="$t/bin:$PATH" scripts/generate_release_manifest.sh 2>&1)"; rc=$?; set -e
  [[ "$rc" -ne 0 ]]; grep -q 'original recovery evidence is preserved at:' <<<"$output"
  previous="$(find "$t/repo/release" -maxdepth 1 -type f -name '.SHA256SUMS.previous.*' -print -quit)"
  [[ -n "$previous" && "$(cat "$previous")" == "$before" ]]
}

run_case 'harness intermediate failure is detected' harness_intermediate_failure_is_detected
run_case 'atomic existing destination is untouched' atomic_existing_destination_is_untouched
run_case 'atomic real race is untouched' atomic_real_race_is_untouched
run_case 'atomic post-rename replacement is untouched' atomic_post_rename_replacement_is_untouched
run_case 'atomic displace post-rename replacement is untouched' atomic_displace_post_rename_replacement_is_untouched
run_case 'staging replacement before failure cleanup is untouched' staging_replacement_before_failure_cleanup_is_untouched
run_case 'direct installer ignores inherited test mode' direct_installer_ignores_inherited_test_mode
run_case 'state publication real race preserves both sides' state_publication_real_race_preserves_both_sides
run_case 'launcher publication real race preserves operator file' launcher_publication_real_race_preserves_operator_file
run_case 'backup rotation real race preserves operator destination' backup_rotation_real_race_preserves_operator_destination
run_case 'manifest corrupt previous-copy success is rejected' manifest_previous_copy_corrupt_success_is_rejected
run_case 'manifest real race preserves operator destination' manifest_real_race_preserves_operator_destination
run_case 'manifest displace post-rename replacement is untouched' manifest_displace_post_rename_replacement_is_untouched
run_case 'direct manifest ignores inherited test variables' direct_manifest_ignores_inherited_test_variables
run_case 'manifest corrupt recovery preserves original previous copy' manifest_corrupt_recovery_preserves_original_previous_copy
printf 'atomic publication regressions: %d/15 PASS\n' "$pass"
