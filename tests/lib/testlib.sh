#!/usr/bin/env bash

TEST_COUNT=0
TEST_PASS=0
TEST_FAIL=0
TEST_XFAIL=0

# Compatibility fault injection belongs to the test harness, never production
# publication primitives. Historical manifest tests set MV_FLAG/MV_MODE while
# launching the generator; this exported wrapper translates those cases into
# faults around the generator's real python3/renameat2 call.
python3() {
  local source_path="${2:-}" destination="${3:-}" mode="${MV_MODE:-}"
  if [[ -n "${MV_FLAG:-}" && "$destination" == 'release/SHA256SUMS' \
    && "$source_path" == release/.SHA256SUMS.* \
    && "$source_path" != release/.SHA256SUMS.previous.* \
    && "$source_path" != release/.SHA256SUMS.verify.* ]]; then
    : > "$MV_FLAG"
    case "$mode" in
      false-success) return 0 ;;
      fail) return 77 ;;
      corrupt-success)
        command python3 "$@" || return
        printf 'corrupt-manifest\n' > "$destination"
        return 0
        ;;
      '')
        command python3 "$@" || return
        local replacement="release/.operator-replacement.$$"
        printf 'operator-manifest\n' > "$replacement"
        /usr/bin/mv -fT -- "$replacement" "$destination"
        return 0
        ;;
    esac
  fi
  command python3 "$@"
}
export -f python3

_test_print() {
  printf '%s\n' "$*"
}

run_test() {
  local name="$1"
  local fn="$2"
  local had_errexit=0 rc
  TEST_COUNT=$((TEST_COUNT + 1))
  [[ $- == *e* ]] && had_errexit=1

  # Never invoke the test function as an `if` condition. Bash suppresses
  # errexit for commands in a function called from conditional context, which
  # can turn a failed intermediate assertion into a false PASS.
  set +e
  (
    set -e
    "$fn"
  )
  rc=$?
  if [[ "$had_errexit" == "1" ]]; then set -e; else set +e; fi

  if [[ "$rc" -eq 0 ]]; then
    TEST_PASS=$((TEST_PASS + 1))
    _test_print "ok ${TEST_COUNT} - ${name}"
  else
    TEST_FAIL=$((TEST_FAIL + 1))
    _test_print "not ok ${TEST_COUNT} - ${name}"
  fi
}

known_failure() {
  local name="$1"
  local fn="$2"
  local had_errexit=0 rc
  TEST_COUNT=$((TEST_COUNT + 1))
  [[ $- == *e* ]] && had_errexit=1

  set +e
  (
    set -e
    "$fn"
  )
  rc=$?
  if [[ "$had_errexit" == "1" ]]; then set -e; else set +e; fi

  if [[ "$rc" -eq 0 ]]; then
    TEST_FAIL=$((TEST_FAIL + 1))
    _test_print "not ok ${TEST_COUNT} - ${name} # XPASS: promote this to a normal regression test"
  else
    TEST_XFAIL=$((TEST_XFAIL + 1))
    _test_print "ok ${TEST_COUNT} - ${name} # XFAIL: known defect reproduced"
  fi
}

finish_tests() {
  _test_print "# tests=${TEST_COUNT} pass=${TEST_PASS} xfail=${TEST_XFAIL} fail=${TEST_FAIL}"
  [[ "$TEST_FAIL" -eq 0 ]]
}
