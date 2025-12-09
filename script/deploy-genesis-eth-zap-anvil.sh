#!/usr/bin/env bash

set -euo pipefail

# Deploy GenesisETHZap_v3 to Anvil
# Usage: GENESIS_ETH=0x... bash script/deploy-genesis-eth-zap-anvil.sh

# Load environment variables from .env.local if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ -f .env.local ]]; then
  set -a
  source .env.local
  set +a
fi

# Use full path to forge/cast
FORGE=${FORGE:-$HOME/.foundry/bin/forge}
CAST=${CAST:-$HOME/.foundry/bin/cast}

# Load required variables from .env.local (no hardcoded defaults)
RPC_URL=${RPC_URL}
PRIVATE_KEY=${PRIVATE_KEY}
GENESIS_ETH=${GENESIS_ETH}

# Validate required variables
if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${GENESIS_ETH:-}" ]]; then
  echo "ERROR: GENESIS_ETH must be set in .env.local or as environment variable"
  exit 1
fi

# Lido referral address (optional, use address(0) for default)
REFERRAL_ETH=${REFERRAL_ETH:-0x0000000000000000000000000000000000000000}

# Check network
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")

echo "=== Deploying GenesisETHZap_v3 to Anvil ==="
echo "RPC URL: $RPC_URL"
echo "Chain ID: $CHAIN_ID"
echo "Genesis Contract: $GENESIS_ETH"
echo "Referral: $REFERRAL_ETH (will use default if zero)"
echo ""

# Deploy GenesisETHZap_v3
# Constructor: (address genesis_, address referral_)
echo "Deploying GenesisETHZap_v3..."
GENESIS_ETH_ZAP_OUT=$("$FORGE" create src/minter/GenesisETHZap_v3.sol:GenesisETHZapV3 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$GENESIS_ETH" "$REFERRAL_ETH" 2>&1)

if echo "$GENESIS_ETH_ZAP_OUT" | grep -q "Deployed to:"; then
  GENESIS_ETH_ZAP_ADDR=$(echo "$GENESIS_ETH_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ GenesisETHZap_v3 deployed to: $GENESIS_ETH_ZAP_ADDR"
else
  echo "  ✗ GenesisETHZap_v3 deployment failed"
  echo "$GENESIS_ETH_ZAP_OUT" | grep -E "(Error|error|revert)" | head -5
  exit 1
fi

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo "GenesisETHZap_v3: $GENESIS_ETH_ZAP_ADDR"
echo "Genesis Contract: $GENESIS_ETH"
echo ""

# Verification
echo "=== VERIFICATION ==="
GENESIS_CHECK=$("$CAST" call "$GENESIS_ETH_ZAP_ADDR" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
OWNER_CHECK=$("$CAST" call "$GENESIS_ETH_ZAP_ADDR" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
REFERRAL_CHECK=$("$CAST" call "$GENESIS_ETH_ZAP_ADDR" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")

if [[ "$GENESIS_CHECK" == "$GENESIS_ETH" ]]; then
  echo "  ✓ GENESIS:  $GENESIS_CHECK"
else
  echo "  ✗ GENESIS:  $GENESIS_CHECK (expected: $GENESIS_ETH)"
fi

if [[ "$OWNER_CHECK" != "ERROR" ]]; then
  echo "  ✓ Owner:    $OWNER_CHECK"
else
  echo "  ✗ Owner:    Failed to read"
fi

if [[ "$REFERRAL_CHECK" != "ERROR" ]]; then
  echo "  ✓ Referral: $REFERRAL_CHECK"
else
  echo "  ✗ Referral: Failed to read"
fi

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Contract Address: $GENESIS_ETH_ZAP_ADDR"
echo ""
echo "You can now interact with the contract using:"
echo "  cast call $GENESIS_ETH_ZAP_ADDR \"totalValueETH()(uint256)\" --rpc-url $RPC_URL"
echo "  cast call $GENESIS_ETH_ZAP_ADDR \"previewDepositETH(uint256)(uint256,uint256,uint256)\" 1000000000000000000 --rpc-url $RPC_URL"

