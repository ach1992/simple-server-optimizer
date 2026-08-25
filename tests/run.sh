#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mapfile -t test_files < <(find tests -maxdepth 1 -type f -name 'test_*.sh' -print | sort)

if [[ "${#test_files[@]}" -eq 0 ]]; then
  printf 'No tests found.\n' >&2
  exit 1
fi

failed=0
for test_file in "${test_files[@]}"; do
  printf '\n==> %s\n' "$test_file"
  if ! bash "$test_file"; then
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  printf '\nTest suite failed.\n' >&2
  exit 1
fi

printf '\nAll test files passed.\n'
