#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PAYLOAD_FILES=(
  install.sh
  sso.sh
  modules/utils.sh
  modules/network.sh
  modules/cpu_irq.sh
  modules/firewall.sh
  modules/fail2ban.sh
  modules/rollback.sh
  modules/uninstall.sh
  assets/whitelist-default.ipv4
  assets/blocklist-ip.ipv4
)

for f in "${PAYLOAD_FILES[@]}"; do
  [[ -f "$f" && ! -L "$f" && -s "$f" ]] || {
    printf 'Missing or unsafe release payload file: %s\n' "$f" >&2
    exit 1
  }
done

if [[ -L release || ( -e release && ! -d release ) ]]; then
  printf 'Refusing unsafe release directory.\n' >&2
  exit 1
fi
mkdir -p release
manifest_tmp="$(mktemp release/.SHA256SUMS.XXXXXX)" || exit 1
if ! sha256sum "${PAYLOAD_FILES[@]}" > "$manifest_tmp"; then
  rm -f -- "$manifest_tmp"
  printf 'Could not generate release checksums.\n' >&2
  exit 1
fi
if ! mv -f -- "$manifest_tmp" release/SHA256SUMS; then
  rm -f -- "$manifest_tmp"
  printf 'Could not publish release checksum manifest.\n' >&2
  exit 1
fi
printf 'Wrote release/SHA256SUMS for %d payload files.\n' "${#PAYLOAD_FILES[@]}"
