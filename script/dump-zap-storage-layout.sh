#!/usr/bin/env bash
# Print storage layout for UUPS zap implementations (run after `forge build`).
# For upgrades: save JSON (`forge inspect <Name> storageLayout --json`) from the
# current mainnet implementation and diff against this output before upgrading.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build --quiet
for c in GenesisETHZap_v5 GenesisUSDCZap_v5 MinterETHZap_v4 MinterUSDCZap_v4; do
  echo "========== ${c} =========="
  forge inspect "$c" storageLayout
  echo
done
