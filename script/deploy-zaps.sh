#!/usr/bin/env bash

set -euo pipefail

# Harbor Zap Contracts Deployment Script v2
# Deploys 4 zap contracts (GenesisETHZap, GenesisUSDCZap, MinterETHZap, MinterUSDCZap)

# Use full path to forge/cast
FORGE=${FORGE:-$HOME/.foundry/bin/forge}
CAST=${CAST:-$HOME/.foundry/bin/cast}

RPC_URL=${RPC_URL:-http://127.0.0.1:8545}
PRIVATE_KEY=${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
OWNER=${OWNER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}

# Check network
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")

echo "=== Network Check ==="
echo "RPC URL: $RPC_URL"
echo "Chain ID: $CHAIN_ID"

if [[ "$CHAIN_ID" == "0xa4b1" ]] || [[ "$CHAIN_ID" == "42161" ]]; then
  echo "⚠️  WARNING: This script uses Ethereum mainnet addresses!"
  echo "   For Arbitrum deployment, update contract addresses accordingly."
  echo "   Press Ctrl+C to cancel, or wait 5 seconds to continue..."
  sleep 5
fi

echo ""

# Contract addresses (Ethereum mainnet)
# These should be set to your deployed Genesis and Minter contracts
GENESIS_ETH=${GENESIS_ETH:-0x0000000000000000000000000000000000000000}
GENESIS_USDC=${GENESIS_USDC:-0x0000000000000000000000000000000000000000}
MINTER_ETH=${MINTER_ETH:-0x0000000000000000000000000000000000000000}
MINTER_USDC=${MINTER_USDC:-0x0000000000000000000000000000000000000000}

# Lido referral address (optional, defaults to Harbor's referral)
REFERRAL_ETH=${REFERRAL_ETH:-0x3dFc49e5112005179Da613BdE5973229082dAc35}

# Validate required addresses
if [[ "$GENESIS_ETH" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: GENESIS_ETH must be set to a valid Genesis contract address"
  exit 1
fi

if [[ "$GENESIS_USDC" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: GENESIS_USDC must be set to a valid Genesis contract address"
  exit 1
fi

if [[ "$MINTER_ETH" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: MINTER_ETH must be set to a valid Minter contract address"
  exit 1
fi

if [[ "$MINTER_USDC" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: MINTER_USDC must be set to a valid Minter contract address"
  exit 1
fi

echo "=== Deploying 4 Zap Contracts ==="
echo ""

# Helper function to deploy zap contract
deploy_zap() {
  local contract_name=$1
  local contract_path=$2
  local constructor_args=$3
  
  echo "Deploying $contract_name..."
  
  DEPLOY_OUT=$("$FORGE" create "$contract_path" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    --constructor-args $constructor_args 2>&1)
  
  if [[ $? -ne 0 ]] || ! echo "$DEPLOY_OUT" | grep -q "Deployed to:"; then
    echo "ERROR: $contract_name deployment failed!" >&2
    echo "Error output:" >&2
    echo "$DEPLOY_OUT" | grep -E "(Error|error|revert|Revert)" | head -5 >&2
    return 1
  fi
  
  DEPLOYED=$(grep -Eo "Deployed to: 0x[0-9a-fA-F]{40}" <<<"$DEPLOY_OUT" | awk '{print $3}')
  echo "  $contract_name: $DEPLOYED"
  echo "$DEPLOYED"
}

# 1. Deploy GenesisETHZap_v2
# Constructor: (address genesis_, address referral_)
GENESIS_ETH_ZAP=$(deploy_zap "GenesisETHZap_v2" \
  "src/minter/GenesisETHZap_v2.sol:GenesisETHZapV2" \
  "$GENESIS_ETH $REFERRAL_ETH")

# 2. Deploy GenesisUSDCZap_v2
# Constructor: (address genesis_)
GENESIS_USDC_ZAP=$(deploy_zap "GenesisUSDCZap_v2" \
  "src/minter/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2" \
  "$GENESIS_USDC")

# 3. Deploy MinterETHZap_v2
# Constructor: (address minter_, address referral_)
MINTER_ETH_ZAP=$(deploy_zap "MinterETHZap_v2" \
  "src/minter/MinterETHZap_v2.sol:MinterETHZapV2" \
  "$MINTER_ETH $REFERRAL_ETH")

# 4. Deploy MinterUSDCZap_v2
# Constructor: (address minter_)
MINTER_USDC_ZAP=$(deploy_zap "MinterUSDCZap_v2" \
  "src/minter/MinterUSDCZap_v2.sol:MinterUSDCZapV2" \
  "$MINTER_USDC")

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo ""
echo "GENESIS ZAPS (2 contracts):"
echo "  GenesisETHZap:  $GENESIS_ETH_ZAP"
echo "  GenesisUSDCZap: $GENESIS_USDC_ZAP"
echo ""
echo "MINTER ZAPS (2 contracts):"
echo "  MinterETHZap:   $MINTER_ETH_ZAP"
echo "  MinterUSDCZap:  $MINTER_USDC_ZAP"
echo ""

# Verify deployments
echo "=== VERIFICATION ==="
echo ""

# Check owner addresses
echo "Checking owners..."
echo -n "  GenesisETHZap owner:  "
"$CAST" call "$GENESIS_ETH_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  GenesisUSDCZap owner: "
"$CAST" call "$GENESIS_USDC_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  MinterETHZap owner:   "
"$CAST" call "$MINTER_ETH_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  MinterUSDCZap owner:  "
"$CAST" call "$MINTER_USDC_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""

# Check linked contracts
echo "Checking linked contracts..."
echo -n "  GenesisETHZap GENESIS:  "
"$CAST" call "$GENESIS_ETH_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  GenesisUSDCZap GENESIS: "
"$CAST" call "$GENESIS_USDC_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  MinterETHZap MINTER:   "
"$CAST" call "$MINTER_ETH_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  MinterUSDCZap MINTER:  "
"$CAST" call "$MINTER_USDC_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""

# Check referral (only for ETH zaps)
echo "Checking Lido referral (ETH zaps only)..."
echo -n "  GenesisETHZap referral: "
"$CAST" call "$GENESIS_ETH_ZAP" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  MinterETHZap referral: "
"$CAST" call "$MINTER_ETH_ZAP" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Next steps:"
echo "  1. Transfer ownership of zap contracts to desired owner:"
echo "     cast send $GENESIS_ETH_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $GENESIS_USDC_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_ETH_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_USDC_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo ""
echo "  2. (Optional) Update Lido referral for ETH zaps:"
echo "     cast send $GENESIS_ETH_ZAP \"setReferral(address)\" <NEW_REFERRAL> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_ETH_ZAP \"setReferral(address)\" <NEW_REFERRAL> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"

