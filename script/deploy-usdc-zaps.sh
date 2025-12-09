#!/usr/bin/env bash

set -euo pipefail

# Harbor USDC/fxSAVE Zap Contracts Deployment Script v2
# Deploys GenesisUSDCZap_v2 and MinterUSDCZap_v2

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
OWNER=${OWNER}

# Validate required variables
if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${OWNER:-}" ]]; then
  echo "ERROR: OWNER must be set in .env.local or as environment variable"
  exit 1
fi

# Check network
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")

echo "=== Network Check ==="
echo "RPC URL: $RPC_URL"
echo "Chain ID: $CHAIN_ID"
echo ""

# Contract addresses - must be set in .env.local
GENESIS_USDC=${GENESIS_USDC}
MINTER_USDC=${MINTER_USDC}

# Validate required addresses
if [[ -z "${GENESIS_USDC:-}" ]]; then
  echo "ERROR: GENESIS_USDC must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${MINTER_USDC:-}" ]]; then
  echo "ERROR: MINTER_USDC must be set in .env.local or as environment variable"
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

