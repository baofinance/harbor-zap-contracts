#!/usr/bin/env bash
# Print storage layout for UUPS zap implementations (run after `forge build`).
# For upgrades: save JSON (`forge inspect <Name> storageLayout --json`) from the
# current mainnet implementation and diff against this output before upgrading.
#
# Production v3/v4 → branch v1: layouts are INCOMPATIBLE. See docs/zap-storage-layout-upgrade.md.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build --quiet
for c in GenesisETHZap_v1 GenesisUSDCZap_v1 MinterETHZap_v1 MinterUSDCZap_v1; do
  echo "========== ${c} =========="
  forge inspect "$c" storageLayout
  echo
done
echo "NOTE: Do not UUPS-upgrade production Minter v3 / Genesis v4 proxies to these implementations."
echo "See docs/zap-storage-layout-upgrade.md"
