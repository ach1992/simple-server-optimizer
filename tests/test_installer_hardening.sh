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
  printf 'schema=sso-managed-install-v1\nrepository=ach1992/simple-server-optimizer\n' > "$root/.sso-managed-install"
}


make_lookalike_payload() {
  local root="$1" f
  for f in \
    install.sh sso.sh \
    modules/utils.sh modules/network.sh modules/cpu_irq.sh modules/firewall.sh \
    modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh \
    assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4; do
    mkdir -p "$root/$(dirname "$f")"
    printf 'operator-owned-lookalike:%s\n' "$f" > "$root/$f"
  done
}

make_release_fixture() {
  local root="$1"
  make_installed_payload "$root"
  mkdir -p "$root/release"
  (
    cd "$root" || exit 1
    sha256sum install.sh sso.sh modules/utils.sh modules/network.sh modules/cpu_irq.sh \
      modules/firewall.sh modules/fail2ban.sh modules/rollback.sh modules/uninstall.sh \
      assets/whitelist-default.ipv4 assets/blocklist-ip.ipv4 > release/SHA256SUMS
  )
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

test_manifest_verifier_rejects_unsafe_runtime_file_types() {
  local tmp variant fixture target external
  tmp="$(mktemp -d)" || return 1

  for variant in symlink-identical dangling-symlink directory fifo missing empty; do
    fixture="$tmp/$variant"
    make_release_fixture "$fixture"
    target="$fixture/modules/network.sh"
    case "$variant" in
      symlink-identical)
        external="$tmp/network-identical"
        cp -a "$target" "$external"
        rm -f "$target"
        ln -s "$external" "$target"
        ;;
      dangling-symlink)
        rm -f "$target"
        ln -s "$tmp/does-not-exist" "$target"
        ;;
      directory)
        rm -f "$target"
        mkdir "$target"
        ;;
      fifo)
        rm -f "$target"
        mkfifo "$target"
        ;;
      missing)
        rm -f "$target"
        ;;
      empty)
        : > "$target"
        ;;
    esac

    if ROOT_DIR="$ROOT_DIR" FIXTURE="$fixture" bash -c '
      set -Eeuo pipefail
      export SSO_INSTALL_LIB_ONLY=1
      source "$ROOT_DIR/install.sh"
      verify_release_manifest "$FIXTURE"
    ' >/dev/null 2>&1; then
      rm -rf "$tmp"
      return 1
    fi
  done

  fixture="$tmp/parent-symlink"
  make_release_fixture "$fixture"
  mv "$fixture/modules" "$tmp/external-modules"
  ln -s "$tmp/external-modules" "$fixture/modules"
  if ROOT_DIR="$ROOT_DIR" FIXTURE="$fixture" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    source "$ROOT_DIR/install.sh"
    verify_release_manifest "$FIXTURE"
  ' >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
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

test_pre_activation_failure_matrix_preserves_current_install() {
  local tmp mode case_root
  tmp="$(mktemp -d)" || return 1

  for mode in stage-mktemp copy chmod validation marker backup-remove current-to-backup; do
    case_root="$tmp/$mode"
    make_installed_payload "$case_root/install"
    printf 'previous-%s\n' "$mode" > "$case_root/install/PREVIOUS"
    if [[ "$mode" == "backup-remove" ]]; then
      make_installed_payload "$case_root/install.bak"
      printf 'old-backup\n' > "$case_root/install.bak/OLD_BACKUP"
    fi

    ROOT_DIR="$ROOT_DIR" CASE_ROOT="$case_root" MODE="$mode" bash -c '
      set -Eeuo pipefail
      export SSO_INSTALL_LIB_ONLY=1
      export SSO_INSTALL_DIR="$CASE_ROOT/install"
      export SSO_STATE_DIR="$CASE_ROOT/state"
      export SSO_LAUNCHER_PATH="$CASE_ROOT/bin/sso"
      source "$ROOT_DIR/install.sh"
      err() { :; }
      info() { :; }
      ok() { :; }

      case "$MODE" in
        stage-mktemp)
          mktemp() {
            if [[ "$*" == *"$INSTALL_DIR.new."* ]]; then : > "$CASE_ROOT/INJECTED"; return 81; fi
            command mktemp "$@"
          }
          ;;
        copy)
          cp() {
            local destination="${@: -1}" source="${@: -2:1}"
            if [[ "$destination" == "$INSTALL_DIR.new."*/modules/network.sh && "$source" == */modules/network.sh ]]; then
              : > "$CASE_ROOT/INJECTED"; return 82
            fi
            command cp "$@"
          }
          ;;
        chmod)
          chmod() {
            if [[ "${1:-}" == "+x" && "${2:-}" == "$INSTALL_DIR.new."*/install.sh ]]; then
              : > "$CASE_ROOT/INJECTED"; return 83
            fi
            command chmod "$@"
          }
          ;;
        validation)
          eval "$(declare -f validate_payload | sed "1s/validate_payload/original_validate_payload/")"
          validate_calls=0
          validate_payload() {
            validate_calls=$((validate_calls + 1))
            if [[ "$validate_calls" -eq 2 ]]; then : > "$CASE_ROOT/INJECTED"; return 84; fi
            original_validate_payload "$@"
          }
          ;;
        marker)
          chmod() {
            if [[ "${1:-}" == "0644" && "${2:-}" == "$INSTALL_DIR.new."*/.sso-managed-install ]]; then
              : > "$CASE_ROOT/INJECTED"; return 85
            fi
            command chmod "$@"
          }
          ;;
        backup-remove)
          rm() {
            local arg
            for arg in "$@"; do
              if [[ "$arg" == "$INSTALL_DIR.bak" ]]; then : > "$CASE_ROOT/INJECTED"; return 86; fi
            done
            command rm "$@"
          }
          ;;
        current-to-backup)
          mv() {
            local destination="${@: -1}" source="${@: -2:1}"
            if [[ "$source" == "$INSTALL_DIR" && "$destination" == "$INSTALL_DIR.bak" ]]; then
              : > "$CASE_ROOT/INJECTED"; return 87
            fi
            command mv "$@"
          }
          ;;
      esac

      if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
      [[ -f "$CASE_ROOT/INJECTED" ]]
      [[ -f "$INSTALL_DIR/PREVIOUS" ]]
      if [[ "$MODE" == "backup-remove" ]]; then
        [[ -f "$INSTALL_DIR.bak/OLD_BACKUP" ]]
      else
        [[ ! -e "$INSTALL_DIR.bak" ]]
      fi
      ! compgen -G "$INSTALL_DIR.new.*" >/dev/null
    ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  done

  rm -rf "$tmp"
}

test_state_temp_creation_failure_rolls_back_to_previous_install() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  printf 'previous\n' > "$tmp/install/PREVIOUS"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    mktemp() {
      if [[ "$*" == *"$STATE_DIR/.install_dir."* ]]; then : > "$TMPROOT/STATE_TEMP_FAILED"; return 88; fi
      command mktemp "$@"
    }
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$TMPROOT/STATE_TEMP_FAILED" ]]
    [[ -f "$INSTALL_DIR/PREVIOUS" && ! -e "$INSTALL_DIR.bak" ]]
    ! compgen -G "$STATE_DIR/.install_dir.*" >/dev/null
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_backup_restore_move_failure_preserves_recovery_evidence() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  printf 'previous\n' > "$tmp/install/PREVIOUS"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    mktemp() {
      if [[ "$*" == *"$STATE_DIR/.install_dir."* ]]; then : > "$TMPROOT/STATE_TEMP_FAILED"; return 89; fi
      command mktemp "$@"
    }
    mv() {
      local destination="${@: -1}" source="${@: -2:1}"
      if [[ "$source" == "$INSTALL_DIR.bak" && "$destination" == "$INSTALL_DIR" ]]; then
        : > "$TMPROOT/RESTORE_MOVE_FAILED"
        return 90
      fi
      command mv "$@"
    }
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$TMPROOT/STATE_TEMP_FAILED" && -f "$TMPROOT/RESTORE_MOVE_FAILED" ]]
    [[ ! -e "$INSTALL_DIR" && -f "$INSTALL_DIR.bak/PREVIOUS" ]]
  ' >/dev/null 2>&1
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
      local src="${@: -2:1}" dst="${@: -1}"
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

test_activation_race_preserves_unrelated_destination_and_previous_backup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  printf 'previous\n' > "$tmp/install/PREVIOUS"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    mv() {
      local destination="${@: -1}" source="${@: -2:1}"
      if [[ "$source" == "$INSTALL_DIR.new."* && "$destination" == "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        printf "operator-race\n" > "$INSTALL_DIR/OPERATOR"
        : > "$TMPROOT/ACTIVATION_RACE"
        return 91
      fi
      command mv "$@"
    }
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$TMPROOT/ACTIVATION_RACE" ]]
    [[ -f "$INSTALL_DIR/OPERATOR" ]]
    [[ ! -e "$INSTALL_DIR/$INSTALL_MARKER" && ! -L "$INSTALL_DIR/$INSTALL_MARKER" ]]
    [[ -f "$INSTALL_DIR.bak/PREVIOUS" ]]
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_rollback_removal_failure_preserves_previous_backup() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  make_installed_payload "$tmp/install.bak"
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
        if [[ "$arg" == "$INSTALL_DIR" ]]; then
          : > "$tmp/ROLLBACK_REMOVE_FAILED"
          return 74
        fi
      done
      command rm "$@"
    }

    if rollback_install_activation 1 "$INSTALL_DIR.bak"; then exit 1; fi
    [[ -f "$tmp/ROLLBACK_REMOVE_FAILED" ]]
    [[ -f "$INSTALL_DIR/NEW" ]]
    [[ -f "$INSTALL_DIR.bak/PREVIOUS" ]]
  )
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_state_publish_destination_types_are_checked_before_rotation() {
  local tmp variant case_root
  tmp="$(mktemp -d)" || return 1

  for variant in directory symlink; do
    case_root="$tmp/$variant"
    make_installed_payload "$case_root/install"
    printf 'previous-%s\n' "$variant" > "$case_root/install/PREVIOUS"
    mkdir -p "$case_root/state"
    if [[ "$variant" == "directory" ]]; then
      mkdir "$case_root/state/install_dir"
    else
      printf 'operator-state\n' > "$case_root/operator-state"
      ln -s "$case_root/operator-state" "$case_root/state/install_dir"
    fi

    if ROOT_DIR="$ROOT_DIR" CASE_ROOT="$case_root" bash -c '
      set -Eeuo pipefail
      export SSO_INSTALL_LIB_ONLY=1
      export SSO_INSTALL_DIR="$CASE_ROOT/install"
      export SSO_STATE_DIR="$CASE_ROOT/state"
      export SSO_LAUNCHER_PATH="$CASE_ROOT/bin/sso"
      source "$ROOT_DIR/install.sh"
      install_staged_payload "$ROOT_DIR"
    ' >/dev/null 2>&1; then
      rm -rf "$tmp"
      return 1
    fi
    [[ -f "$case_root/install/PREVIOUS" && ! -e "$case_root/install.bak" ]] || { rm -rf "$tmp"; return 1; }
  done

  case_root="$tmp/regular"
  make_installed_payload "$case_root/install"
  printf 'previous-regular\n' > "$case_root/install/PREVIOUS"
  mkdir -p "$case_root/state"
  printf '%s\n' "$case_root/install" > "$case_root/state/install_dir"
  ROOT_DIR="$ROOT_DIR" CASE_ROOT="$case_root" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$CASE_ROOT/install"
    export SSO_STATE_DIR="$CASE_ROOT/state"
    export SSO_LAUNCHER_PATH="$CASE_ROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    install_staged_payload "$ROOT_DIR"
    [[ -f "$INSTALL_DIR.bak/PREVIOUS" ]]
    cmp -s "$STATE_DIR/install_dir" <(printf "%s\n" "$INSTALL_DIR")
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_state_publish_mv_failure_and_false_success_restore_previous_install() {
  local tmp mode case_root
  tmp="$(mktemp -d)" || return 1

  for mode in fail false-success corrupt-success; do
    case_root="$tmp/$mode"
    make_installed_payload "$case_root/install"
    printf 'previous-%s\n' "$mode" > "$case_root/install/PREVIOUS"
    mkdir -p "$case_root/state"
    printf '%s\n' "$case_root/install" > "$case_root/state/install_dir"

    ROOT_DIR="$ROOT_DIR" CASE_ROOT="$case_root" MODE="$mode" bash -c '
      set -Eeuo pipefail
      export SSO_INSTALL_LIB_ONLY=1
      export SSO_INSTALL_DIR="$CASE_ROOT/install"
      export SSO_STATE_DIR="$CASE_ROOT/state"
      export SSO_LAUNCHER_PATH="$CASE_ROOT/bin/sso"
      source "$ROOT_DIR/install.sh"
      mv() {
        local destination="${@: -1}" source="${@: -2:1}"
        if [[ "$destination" == "$STATE_DIR/install_dir" && "$source" == "$STATE_DIR/.install_dir."* \
          && "$source" != "$STATE_DIR/.install_dir.restore."* && "$source" != "$STATE_DIR/.install_dir.previous."* ]]; then
          : > "$CASE_ROOT/PUBLISH_INJECTED"
          case "$MODE" in
            false-success) return 0 ;;
            fail) return 79 ;;
            corrupt-success)
              command mv "$@" || return
              printf "corrupt-state\n" > "$destination"
              return 0
              ;;
          esac
        fi
        command mv "$@"
      }
      if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
      [[ -f "$CASE_ROOT/PUBLISH_INJECTED" ]]
      [[ -f "$INSTALL_DIR/PREVIOUS" && ! -e "$INSTALL_DIR.bak" ]]
      cmp -s "$STATE_DIR/install_dir" <(printf "%s\n" "$INSTALL_DIR")
      ! compgen -G "$STATE_DIR/.install_dir.*" >/dev/null
    ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  done

  case_root="$tmp/first-install-corrupt-success"
  mkdir -p "$case_root/state"
  ROOT_DIR="$ROOT_DIR" CASE_ROOT="$case_root" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$CASE_ROOT/install"
    export SSO_STATE_DIR="$CASE_ROOT/state"
    export SSO_LAUNCHER_PATH="$CASE_ROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    mv() {
      local destination="${@: -1}" source="${@: -2:1}"
      if [[ "$destination" == "$STATE_DIR/install_dir" && "$source" == "$STATE_DIR/.install_dir."* \
          && "$source" != "$STATE_DIR/.install_dir.restore."* && "$source" != "$STATE_DIR/.install_dir.previous."* ]]; then
        : > "$CASE_ROOT/PUBLISH_INJECTED"
        command mv "$@" || return
        printf "corrupt-state\n" > "$destination"
        return 0
      fi
      command mv "$@"
    }
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$CASE_ROOT/PUBLISH_INJECTED" ]]
    [[ ! -e "$INSTALL_DIR" && ! -e "$INSTALL_DIR.bak" && ! -e "$STATE_DIR/install_dir" ]]
    ! compgen -G "$STATE_DIR/.install_dir.*" >/dev/null
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp"
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

test_install_ownership_requires_positive_identity() {
  local tmp
  tmp="$(mktemp -d)" || return 1

  make_lookalike_payload "$tmp/install"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }
    if installation_is_sso_owned "$INSTALL_DIR"; then exit 1; fi
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR/install.sh" && ! -e "$INSTALL_DIR.bak" ]]
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  # Even if a markerless directory begins as one exact recognized full-payload
  # snapshot, changing any sibling file must revoke destructive authority.
  rm -rf "$tmp/install"
  make_installed_payload "$tmp/install"
  rm -f "$tmp/install/.sso-managed-install"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"

    LEGACY_PAYLOAD_GIT_BLOBS=()
    for f in "${PAYLOAD_FILES[@]}"; do
      identity="$(legacy_git_blob_identity "$INSTALL_DIR/$f")"
      LEGACY_PAYLOAD_GIT_BLOBS+=("$f:$identity")
    done
    legacy_install_is_sso_owned "$INSTALL_DIR"
    installation_is_sso_owned "$INSTALL_DIR"

    printf "operator-owned-sibling\n" > "$INSTALL_DIR/modules/firewall.sh"
    if legacy_install_is_sso_owned "$INSTALL_DIR"; then exit 1; fi
    if installation_is_sso_owned "$INSTALL_DIR"; then exit 1; fi
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  # The production legacy contract itself must cover every payload path exactly
  # once, in the same order, so no un-fingerprinted sibling can be introduced.
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    source "$ROOT_DIR/install.sh"
    [[ ${#LEGACY_PAYLOAD_GIT_BLOBS[@]} -eq ${#PAYLOAD_FILES[@]} ]]
    for i in "${!PAYLOAD_FILES[@]}"; do
      [[ "${LEGACY_PAYLOAD_GIT_BLOBS[$i]%%:*}" == "${PAYLOAD_FILES[$i]}" ]]
    done
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp/install"
  make_installed_payload "$tmp/install"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    managed_install_marker_is_valid "$INSTALL_DIR"
    installation_is_sso_owned "$INSTALL_DIR"

    printf "corrupt\n" > "$INSTALL_DIR/$INSTALL_MARKER"
    if installation_is_sso_owned "$INSTALL_DIR"; then exit 1; fi

    rm -f "$INSTALL_DIR/$INSTALL_MARKER"
    printf "marker-target\n" > "$TMPROOT/marker-target"
    ln -s "$TMPROOT/marker-target" "$INSTALL_DIR/$INSTALL_MARKER"
    if installation_is_sso_owned "$INSTALL_DIR"; then exit 1; fi

    rm -f "$INSTALL_DIR/$INSTALL_MARKER"
    mkdir "$INSTALL_DIR/$INSTALL_MARKER"
    if installation_is_sso_owned "$INSTALL_DIR"; then exit 1; fi
  ' >/dev/null 2>&1
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_backup_ownership_and_orphan_recovery_fail_closed() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  make_installed_payload "$tmp/install"
  printf 'current-evidence\n' > "$tmp/install/CURRENT"
  make_lookalike_payload "$tmp/install.bak"
  printf 'operator-backup\n' > "$tmp/install.bak/KEEP"

  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    err() { :; }
    if install_staged_payload "$ROOT_DIR" >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR/CURRENT" && -f "$INSTALL_DIR.bak/KEEP" ]]
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp/install" "$tmp/install.bak"
  make_installed_payload "$tmp/install.bak"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    if validate_existing_install_state >/dev/null 2>&1; then exit 1; fi
    [[ -f "$INSTALL_DIR.bak/sso.sh" && ! -e "$INSTALL_DIR" ]]
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp/install.bak"
  make_installed_payload "$tmp/real-install"
  ln -s "$tmp/real-install" "$tmp/install"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    if validate_existing_install_state >/dev/null 2>&1; then exit 1; fi
  ' >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }

  rm -f "$tmp/install"
  make_installed_payload "$tmp/install"
  make_installed_payload "$tmp/real-backup"
  ln -s "$tmp/real-backup" "$tmp/install.bak"
  ROOT_DIR="$ROOT_DIR" TMPROOT="$tmp" bash -c '
    set -Eeuo pipefail
    export SSO_INSTALL_LIB_ONLY=1
    export SSO_INSTALL_DIR="$TMPROOT/install"
    export SSO_STATE_DIR="$TMPROOT/state"
    export SSO_LAUNCHER_PATH="$TMPROOT/bin/sso"
    source "$ROOT_DIR/install.sh"
    if validate_existing_install_state >/dev/null 2>&1; then exit 1; fi
  ' >/dev/null 2>&1
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
  local tmp before
  tmp="$(mktemp -d)" || return 1
  generator_fixture "$tmp/repo"
  "$tmp/repo/scripts/generate_release_manifest.sh" >/dev/null || { rm -rf "$tmp"; return 1; }
  before="$(cat "$tmp/repo/release/SHA256SUMS")"
  mkdir -p "$tmp/bin"
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
  [[ "$(cat "$tmp/repo/release/SHA256SUMS")" == "$before" ]]
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

test_manifest_generator_rejects_directory_and_symlink_destinations() {
  local tmp case_root
  tmp="$(mktemp -d)" || return 1

  case_root="$tmp/directory"
  generator_fixture "$case_root"
  mkdir -p "$case_root/release/SHA256SUMS"
  if "$case_root/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then rm -rf "$tmp"; return 1; fi
  [[ -d "$case_root/release/SHA256SUMS" && ! -L "$case_root/release/SHA256SUMS" ]] || { rm -rf "$tmp"; return 1; }

  case_root="$tmp/symlink"
  generator_fixture "$case_root"
  mkdir -p "$case_root/release"
  printf 'operator-manifest\n' > "$case_root/operator-manifest"
  ln -s "$case_root/operator-manifest" "$case_root/release/SHA256SUMS"
  if "$case_root/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then rm -rf "$tmp"; return 1; fi
  [[ -L "$case_root/release/SHA256SUMS" && "$(cat "$case_root/operator-manifest")" == 'operator-manifest' ]] || { rm -rf "$tmp"; return 1; }

  rm -rf "$tmp"
}

test_manifest_generator_mv_failure_and_false_success_preserve_previous_manifest() {
  local tmp mode case_root before
  tmp="$(mktemp -d)" || return 1
  for mode in fail false-success corrupt-success; do
    case_root="$tmp/$mode"
    generator_fixture "$case_root"
    "$case_root/scripts/generate_release_manifest.sh" >/dev/null || { rm -rf "$tmp"; return 1; }
    before="$(cat "$case_root/release/SHA256SUMS")"
    mkdir -p "$case_root/bin"
    cat > "$case_root/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
destination="${@: -1}"
source="${@: -2:1}"
if [[ "$destination" == "release/SHA256SUMS" && "$source" == release/.SHA256SUMS.* \
  && "$source" != release/.SHA256SUMS.previous.* && "$source" != release/.SHA256SUMS.verify.* ]]; then
  : > "$MV_FLAG"
  case "$MV_MODE" in
    false-success) exit 0 ;;
    fail) exit 77 ;;
    corrupt-success)
      /usr/bin/mv "$@"
      printf 'corrupt-manifest\n' > "$destination"
      exit 0
      ;;
  esac
fi
exec /usr/bin/mv "$@"
MOCK
    chmod +x "$case_root/bin/mv"
    if MV_FLAG="$case_root/MV_INJECTED" MV_MODE="$mode" PATH="$case_root/bin:$PATH" \
      "$case_root/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then
      rm -rf "$tmp"
      return 1
    fi
    [[ -f "$case_root/MV_INJECTED" ]] || { rm -rf "$tmp"; return 1; }
    [[ "$(cat "$case_root/release/SHA256SUMS")" == "$before" ]] || { rm -rf "$tmp"; return 1; }
    if find "$case_root/release" -maxdepth 1 -type f -name '.SHA256SUMS.*' -print -quit | grep -q .; then
      rm -rf "$tmp"
      return 1
    fi
  done
  rm -rf "$tmp"
}

test_manifest_hash_validation_avoids_awk_intervals() {
  # Debian 11 ships a pre-interval mawk. Keep SHA256 syntax checks expressed
  # using portable length + character-class predicates instead of `{64}`.
  if grep -Fq '[0-9a-fA-F]{64}' "$ROOT_DIR/install.sh"; then return 1; fi
  if grep -Fq '[0-9a-fA-F]{64}' "$ROOT_DIR/scripts/generate_release_manifest.sh"; then return 1; fi
  grep -Fq 'length($1) != 64 || $1 ~ /[^0-9a-fA-F]/' "$ROOT_DIR/install.sh"
  grep -Fq 'length($1) != 64 || $1 ~ /[^0-9a-fA-F]/' "$ROOT_DIR/scripts/generate_release_manifest.sh"

  local good bad_short bad_char
  good="$(printf '%064d' 0)"
  bad_short="$(printf '%063d' 0)"
  bad_char="${good%?}g"
  printf '%s\n%s\n%s\n' "$good" "$bad_short" "$bad_char" | awk '
    NR == 1 { if (length($1) != 64 || $1 ~ /[^0-9a-fA-F]/) exit 1; next }
    NR > 1 { if (!(length($1) != 64 || $1 ~ /[^0-9a-fA-F]/)) exit 1 }
  '
}

test_manifest_generator_preserves_distinct_inode_replacement() {
  local tmp case_root before recovery_file
  tmp="$(mktemp -d)" || return 1

  case_root="$tmp/with-previous"
  generator_fixture "$case_root"
  "$case_root/scripts/generate_release_manifest.sh" >/dev/null || { rm -rf "$tmp"; return 1; }
  before="$(cat "$case_root/release/SHA256SUMS")"
  mkdir -p "$case_root/bin"
  cat > "$case_root/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
destination="${@: -1}"
source="${@: -2:1}"
if [[ "$destination" == "release/SHA256SUMS" && "$source" == release/.SHA256SUMS.* \
  && "$source" != release/.SHA256SUMS.previous.* && "$source" != release/.SHA256SUMS.verify.* ]]; then
  : > "$MV_FLAG"
  /usr/bin/mv "$@"
  replacement="release/.operator-replacement.$$"
  printf 'operator-manifest\n' > "$replacement"
  /usr/bin/mv -fT -- "$replacement" "$destination"
  exit 0
fi
exec /usr/bin/mv "$@"
MOCK
  chmod +x "$case_root/bin/mv"
  if MV_FLAG="$case_root/MV_INJECTED" PATH="$case_root/bin:$PATH" \
    "$case_root/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  [[ -f "$case_root/MV_INJECTED" ]] || { rm -rf "$tmp"; return 1; }
  [[ "$(cat "$case_root/release/SHA256SUMS")" == 'operator-manifest' ]] || { rm -rf "$tmp"; return 1; }
  recovery_file="$(find "$case_root/release" -maxdepth 1 -type f -name '.SHA256SUMS.previous.*' -print -quit)"
  [[ -n "$recovery_file" && -f "$recovery_file" ]] || { rm -rf "$tmp"; return 1; }
  [[ "$(cat "$recovery_file")" == "$before" ]] || { rm -rf "$tmp"; return 1; }

  case_root="$tmp/without-previous"
  generator_fixture "$case_root"
  mkdir -p "$case_root/bin"
  cat > "$case_root/bin/mv" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
destination="${@: -1}"
source="${@: -2:1}"
if [[ "$destination" == "release/SHA256SUMS" && "$source" == release/.SHA256SUMS.* \
  && "$source" != release/.SHA256SUMS.previous.* && "$source" != release/.SHA256SUMS.verify.* ]]; then
  : > "$MV_FLAG"
  /usr/bin/mv "$@"
  replacement="release/.operator-replacement.$$"
  printf 'operator-manifest\n' > "$replacement"
  /usr/bin/mv -fT -- "$replacement" "$destination"
  exit 0
fi
exec /usr/bin/mv "$@"
MOCK
  chmod +x "$case_root/bin/mv"
  if MV_FLAG="$case_root/MV_INJECTED" PATH="$case_root/bin:$PATH" \
    "$case_root/scripts/generate_release_manifest.sh" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  [[ -f "$case_root/MV_INJECTED" ]] || { rm -rf "$tmp"; return 1; }
  [[ "$(cat "$case_root/release/SHA256SUMS")" == 'operator-manifest' ]] || { rm -rf "$tmp"; return 1; }
  if find "$case_root/release" -maxdepth 1 -type f -name '.SHA256SUMS.previous.*' -print -quit | grep -q .; then
    rm -rf "$tmp"
    return 1
  fi

  rm -rf "$tmp"
}

run_test "runtime paths are canonical and durable state/launcher stay outside replaceable trees" test_runtime_paths_are_canonical_and_persistence_is_independent
run_test "finish_install runs only after successful install/download" test_finish_install_only_runs_after_success
run_test "runtime payload and checksum manifest reject symlink metadata" test_payload_and_manifest_reject_symlinks
run_test "manifest verification rejects symlink, dangling, directory, FIFO, missing, empty, and parent-symlink payloads" test_manifest_verifier_rejects_unsafe_runtime_file_types
run_test "curl failure cannot be hidden by a partial nonempty output" test_failed_curl_cannot_succeed_with_partial_output
run_test "staging/copy/chmod/validation/marker/backup-rotation failures preserve the current install" test_pre_activation_failure_matrix_preserves_current_install
run_test "state temp creation failure rolls back to the previous install" test_state_temp_creation_failure_rolls_back_to_previous_install
run_test "failed backup restore move preserves the recovery backup" test_backup_restore_move_failure_preserves_recovery_evidence
run_test "activation failure restores the previous installation" test_activation_failure_restores_previous_installation
run_test "activation race preserves an unrelated destination and the prior recovery backup" test_activation_race_preserves_unrelated_destination_and_previous_backup
run_test "rollback removal failure preserves the previous backup evidence" test_rollback_removal_failure_preserves_previous_backup
run_test "state publication rejects directory/symlink destinations before rotating a valid install" test_state_publish_destination_types_are_checked_before_rotation
run_test "state publication failure, false success, and postcondition corruption roll back safely" test_state_publish_mv_failure_and_false_success_restore_previous_install
run_test "finish_install propagates a failed SSO launch" test_finish_install_propagates_run_failure
run_test "unrecognized install and recovery paths are preserved" test_unrecognized_install_and_backup_are_preserved
run_test "install ownership requires a managed marker or narrow multi-file legacy identity" test_install_ownership_requires_positive_identity
run_test "backup ownership, orphan backups, and install/backup symlinks fail closed" test_backup_ownership_and_orphan_recovery_fail_closed
run_test "trusted online source ignores environment redirects" test_online_trust_source_ignores_environment_redirects
run_test "production runtime paths ignore environment redirects" test_production_paths_ignore_environment_redirects
run_test "manifest generator rejects symlinked runtime payload" test_manifest_generator_rejects_symlink_payload
run_test "manifest generator rejects directory and symlink checksum destinations" test_manifest_generator_rejects_directory_and_symlink_destinations
run_test "manifest publication failure, false success, and postcondition corruption preserve the previous valid manifest" test_manifest_generator_mv_failure_and_false_success_preserve_previous_manifest
run_test "manifest hash validation avoids non-portable awk interval expressions" test_manifest_hash_validation_avoids_awk_intervals
run_test "manifest recovery preserves a distinct-inode operator replacement" test_manifest_generator_preserves_distinct_inode_replacement
run_test "manifest generation failure preserves the previous manifest" test_manifest_generator_failure_preserves_previous_manifest
finish_tests
