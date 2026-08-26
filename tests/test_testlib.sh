#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

assert_contains() {
  local needle="$1" haystack="$2"
  [[ "$haystack" == *"$needle"* ]]
}

test_intermediate_assertion_failure_cannot_false_pass() {
  local tmp out rc
  tmp="$(mktemp -d)" || return 1
  cat > "$tmp/child.sh" <<'CHILD'
#!/usr/bin/env bash
set -uo pipefail
source "$TESTLIB"
false_then_true() {
  false
  true
}
run_test "intermediate failure" false_then_true
finish_tests
CHILD
  chmod +x "$tmp/child.sh"
  set +e
  out="$(TESTLIB="$ROOT_DIR/tests/lib/testlib.sh" bash "$tmp/child.sh" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || { rm -rf "$tmp"; return 1; }
  assert_contains "not ok 1 - intermediate failure" "$out" || { rm -rf "$tmp"; return 1; }
  assert_contains "# tests=1 pass=0 xfail=0 fail=1" "$out" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

test_harness_preserves_caller_errexit_state() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  cat > "$tmp/child.sh" <<'CHILD'
#!/usr/bin/env bash
set -euo pipefail
source "$TESTLIB"
passes() { true; }
run_test "pass" passes
[[ $- == *e* ]]
finish_tests
CHILD
  chmod +x "$tmp/child.sh"
  TESTLIB="$ROOT_DIR/tests/lib/testlib.sh" bash "$tmp/child.sh" >/dev/null
  local rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Exercise the shared harness through an outer, independent shell so the test
# of run_test() itself cannot be affected by run_test() semantics.
OUTER_COUNT=0
OUTER_PASS=0
OUTER_FAIL=0
run_outer_test() {
  local name="$1" fn="$2"
  OUTER_COUNT=$((OUTER_COUNT + 1))
  if "$fn"; then
    OUTER_PASS=$((OUTER_PASS + 1))
    printf 'ok %d - %s\n' "$OUTER_COUNT" "$name"
    return 0
  fi
  OUTER_FAIL=$((OUTER_FAIL + 1))
  printf 'not ok %d - %s\n' "$OUTER_COUNT" "$name"
  return 1
}

run_outer_test "intermediate assertion failures are not swallowed" test_intermediate_assertion_failure_cannot_false_pass || true
run_outer_test "harness preserves caller errexit state" test_harness_preserves_caller_errexit_state || true
printf '# tests=%d pass=%d xfail=0 fail=%d\n' "$OUTER_COUNT" "$OUTER_PASS" "$OUTER_FAIL"
[[ "$OUTER_FAIL" -eq 0 ]]
