#!/usr/bin/env bash

TEST_COUNT=0
TEST_PASS=0
TEST_FAIL=0
TEST_XFAIL=0

_test_print() {
  printf '%s\n' "$*"
}

run_test() {
  local name="$1"
  local fn="$2"
  TEST_COUNT=$((TEST_COUNT + 1))

  if "$fn"; then
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
  TEST_COUNT=$((TEST_COUNT + 1))

  if "$fn"; then
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
