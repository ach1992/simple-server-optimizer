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
  [[ -s "$f" ]] || {
    printf 'Missing release payload file: %s\n' "$f" >&2
    exit 1
  }
done

mkdir -p release
sha256sum "${PAYLOAD_FILES[@]}" > release/SHA256SUMS
printf 'Wrote release/SHA256SUMS for %d payload files.\n' "${#PAYLOAD_FILES[@]}"
