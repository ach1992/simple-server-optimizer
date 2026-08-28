#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/testlib.sh
source "$ROOT_DIR/tests/lib/testlib.sh"

absent_service_is_already_safely_disabled() {
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    systemctl() {
      case "$1" in
        show) printf "not-found\n" ;;
        unmask|stop|disable|reset-failed) return 0 ;;
        is-active) printf "inactive\n"; return 3 ;;
        is-enabled) return 1 ;;
        *) return 99 ;;
      esac
    }
    uninstall_disable_sso_service sso-firewall.service
  '
}

loaded_service_with_unknown_enablement_fails_closed() {
  ROOT_DIR="$ROOT_DIR" bash -c '
    set -Eeuo pipefail
    source "$ROOT_DIR/modules/utils.sh"
    source "$ROOT_DIR/modules/uninstall.sh"
    systemctl() {
      case "$1" in
        show) printf "loaded\n" ;;
        unmask|stop|disable|reset-failed) return 0 ;;
        is-active) printf "inactive\n"; return 3 ;;
        is-enabled) return 1 ;;
        *) return 99 ;;
      esac
    }
    if uninstall_disable_sso_service sso-firewall.service; then
      exit 1
    fi
  '
}

run_test "uninstall accepts a positively absent SSO service" absent_service_is_already_safely_disabled
run_test "uninstall rejects empty enablement for a loaded service" loaded_service_with_unknown_enablement_fails_closed
finish_tests
