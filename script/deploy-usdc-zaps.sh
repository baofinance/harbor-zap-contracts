#!/usr/bin/env bash

set -euo pipefail

# Harbor USDC/fxSAVE Zap Contracts Deployment Script v2
# Deploys GenesisUSDCZap_v2 and MinterUSDCZap_v2

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
echo ""

# Contract addresses (Ethereum mainnet)
GENESIS_USDC=${GENESIS_USDC:-0x0000000000000000000000000000000000000000}
MINTER_USDC=${MINTER_USDC:-0x0000000000000000000000000000000000000000}

# Validate required addresses
if [[ "$GENESIS_USDC" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: GENESIS_USDC must be set to a valid Genesis contract address"
  exit 1
fi

if [[ "$MINTER_USDC" == "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: MINTER_USDC must be set to a valid Minter contract address"
  exit 1
fi

echo "=== Deploying USDC/fxSAVE Zap Contracts ==="
echo ""

# 1. Deploy GenesisUSDCZap_v2
# Constructor: (address genesis_)
echo "1. Deploying GenesisUSDCZap_v2..."
GENESIS_USDC_ZAP_OUT=$("$FORGE" create src/minter/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$GENESIS_USDC" 2>&1)

if echo "$GENESIS_USDC_ZAP_OUT" | grep -q "Deployed to:"; then
  GENESIS_USDC_ZAP_ADDR=$(echo "$GENESIS_USDC_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ GenesisUSDCZap_v2 deployed to: $GENESIS_USDC_ZAP_ADDR"
elif echo "$GENESIS_USDC_ZAP_OUT" | grep -q "Contract:"; then
  echo "  ✓ GenesisUSDCZap_v2 deployment prepared"
else
  echo "  ✗ GenesisUSDCZap_v2 deployment failed"
  echo "$GENESIS_USDC_ZAP_OUT" | grep -E "(Error|error|revert)" | head -3
  exit 1
fi

# 2. Deploy MinterUSDCZap_v2
# Constructor: (address minter_)
echo "2. Deploying MinterUSDCZap_v2..."
MINTER_USDC_ZAP_OUT=$("$FORGE" create src/minter/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$MINTER_USDC" 2>&1)

if echo "$MINTER_USDC_ZAP_OUT" | grep -q "Deployed to:"; then
  MINTER_USDC_ZAP_ADDR=$(echo "$MINTER_USDC_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ MinterUSDCZap_v2 deployed to: $MINTER_USDC_ZAP_ADDR"
elif echo "$MINTER_USDC_ZAP_OUT" | grep -q "Contract:"; then
  echo "  ✓ MinterUSDCZap_v2 deployment prepared"
else
  echo "  ✗ MinterUSDCZap_v2 deployment failed"
  echo "$MINTER_USDC_ZAP_OUT" | grep -E "(Error|error|revert)" | head -3
  exit 1
fi

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo ""
echo "USDC/fxSAVE ZAPS (2 contracts):"
if [[ -n "${GENESIS_USDC_ZAP_ADDR:-}" ]]; then
  echo "  GenesisUSDCZap:  $GENESIS_USDC_ZAP_ADDR"
else
  echo "  GenesisUSDCZap:  See deployment output above"
fi
if [[ -n "${MINTER_USDC_ZAP_ADDR:-}" ]]; then
  echo "  MinterUSDCZap:   $MINTER_USDC_ZAP_ADDR"
else
  echo "  MinterUSDCZap:   See deployment output above"
fi
echo ""
echo "Configuration:"
echo "  Genesis:  $GENESIS_USDC"
echo "  Minter:   $MINTER_USDC"

# Verification
if [[ -n "${GENESIS_USDC_ZAP_ADDR:-}" ]] && [[ -n "${MINTER_USDC_ZAP_ADDR:-}" ]]; then
  echo ""
  echo "=== VERIFICATION ==="
  echo ""
  
  # Verify GenesisUSDCZap_v2
  echo "GenesisUSDCZap_v2 ($GENESIS_USDC_ZAP_ADDR):"
  GENESIS_CHECK=$("$CAST" call "$GENESIS_USDC_ZAP_ADDR" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  OWNER_CHECK=$("$CAST" call "$GENESIS_USDC_ZAP_ADDR" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  
  if [[ "$GENESIS_CHECK" == "$GENESIS_USDC" ]]; then
    echo "  ✓ GENESIS:  $GENESIS_CHECK"
  else
    echo "  ✗ GENESIS:  $GENESIS_CHECK (expected: $GENESIS_USDC)"
  fi
  
  if [[ "$OWNER_CHECK" != "ERROR" ]]; then
    echo "  ✓ Owner:    $OWNER_CHECK"
  else
    echo "  ✗ Owner:    Failed to read"
  fi
  
  echo ""
  
  # Verify MinterUSDCZap_v2
  echo "MinterUSDCZap_v2 ($MINTER_USDC_ZAP_ADDR):"
  MINTER_CHECK=$("$CAST" call "$MINTER_USDC_ZAP_ADDR" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  OWNER_CHECK2=$("$CAST" call "$MINTER_USDC_ZAP_ADDR" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  
  if [[ "$MINTER_CHECK" == "$MINTER_USDC" ]]; then
    echo "  ✓ MINTER:   $MINTER_CHECK"
  else
    echo "  ✗ MINTER:   $MINTER_CHECK (expected: $MINTER_USDC)"
  fi
  
  if [[ "$OWNER_CHECK2" != "ERROR" ]]; then
    echo "  ✓ Owner:    $OWNER_CHECK2"
  else
    echo "  ✗ Owner:    Failed to read"
  fi
fi

echo ""
echo "✅ Deployment complete!"

