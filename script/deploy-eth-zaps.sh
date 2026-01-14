#!/usr/bin/env bash

set -euo pipefail

# Harbor ETH/wstETH Zap Contracts Deployment Script
# Deploys GenesisETHZap_v3 and MinterETHZap_v2

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
GENESIS_ETH=${GENESIS_ETH}
MINTER_ETH=${MINTER_ETH}

# Validate required contract addresses
if [[ -z "${GENESIS_ETH:-}" ]]; then
  echo "ERROR: GENESIS_ETH must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${MINTER_ETH:-}" ]]; then
  echo "ERROR: MINTER_ETH must be set in .env.local or as environment variable"
  exit 1
fi

# Lido referral address (optional, can be set in .env.local)
REFERRAL_ETH=${REFERRAL_ETH:-0x0000000000000000000000000000000000000000}

echo "=== Deploying ETH/wstETH Zap Contracts ==="
echo ""

# 1. Deploy GenesisETHZap_v3
# Constructor: (address genesis_, address referral_)
echo "1. Deploying GenesisETHZap_v3..."
GENESIS_ETH_ZAP_OUT=$("$FORGE" create src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$GENESIS_ETH" "$REFERRAL_ETH" 2>&1)

CONTRACT_NAME="GenesisETHZap_v3"

if echo "$GENESIS_ETH_ZAP_OUT" | grep -q "Deployed to:"; then
  GENESIS_ETH_ZAP_ADDR=$(echo "$GENESIS_ETH_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ $CONTRACT_NAME deployed to: $GENESIS_ETH_ZAP_ADDR"
elif echo "$GENESIS_ETH_ZAP_OUT" | grep -q "Contract:"; then
  echo "  ✓ $CONTRACT_NAME deployment prepared"
else
  echo "  ✗ $CONTRACT_NAME deployment failed"
  echo "$GENESIS_ETH_ZAP_OUT" | grep -E "(Error|error|revert)" | head -3
  exit 1
fi

# 2. Deploy MinterETHZap_v2
# Constructor: (address minter_, address referral_)
echo "2. Deploying MinterETHZap_v2..."
MINTER_ETH_ZAP_OUT=$("$FORGE" create src/zap/MinterETHZap_v2.sol:MinterETHZapV2 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$MINTER_ETH" "$REFERRAL_ETH" 2>&1)

if echo "$MINTER_ETH_ZAP_OUT" | grep -q "Deployed to:"; then
  MINTER_ETH_ZAP_ADDR=$(echo "$MINTER_ETH_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ MinterETHZap_v2 deployed to: $MINTER_ETH_ZAP_ADDR"
elif echo "$MINTER_ETH_ZAP_OUT" | grep -q "Contract:"; then
  echo "  ✓ MinterETHZap_v2 deployment prepared"
else
  echo "  ✗ MinterETHZap_v2 deployment failed"
  echo "$MINTER_ETH_ZAP_OUT" | grep -E "(Error|error|revert)" | head -3
  exit 1
fi

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo ""
echo "ETH/wstETH ZAPS (2 contracts):"
if [[ -n "${GENESIS_ETH_ZAP_ADDR:-}" ]]; then
  echo "  GenesisETHZap:  $GENESIS_ETH_ZAP_ADDR"
else
  echo "  GenesisETHZap:  See deployment output above"
fi
if [[ -n "${MINTER_ETH_ZAP_ADDR:-}" ]]; then
  echo "  MinterETHZap:   $MINTER_ETH_ZAP_ADDR"
else
  echo "  MinterETHZap:   See deployment output above"
fi
echo ""
echo "Configuration:"
echo "  Genesis:  $GENESIS_ETH"
echo "  Minter:   $MINTER_ETH"
echo "  Referral: $REFERRAL_ETH"

# Verification
if [[ -n "${GENESIS_ETH_ZAP_ADDR:-}" ]] && [[ -n "${MINTER_ETH_ZAP_ADDR:-}" ]]; then
  echo ""
  echo "=== VERIFICATION ==="
  echo ""
  
  # Verify GenesisETHZap
  echo "$CONTRACT_NAME ($GENESIS_ETH_ZAP_ADDR):"
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
  
  if [[ "$REFERRAL_CHECK" == "$REFERRAL_ETH" ]]; then
    echo "  ✓ Referral: $REFERRAL_CHECK"
  else
    echo "  ✗ Referral: $REFERRAL_CHECK (expected: $REFERRAL_ETH)"
  fi
  
  echo ""
  echo "  V3 View Functions:"
  TOTAL_VALUE=$("$CAST" call "$GENESIS_ETH_ZAP_ADDR" "totalValueETH()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  if [[ "$TOTAL_VALUE" != "ERROR" ]]; then
    echo "  ✓ totalValueETH(): $TOTAL_VALUE"
  else
    echo "  ✗ totalValueETH(): Failed to read"
  fi
  
  echo ""
  
  # Verify MinterETHZap_v2
  echo "MinterETHZap_v2 ($MINTER_ETH_ZAP_ADDR):"
  MINTER_CHECK=$("$CAST" call "$MINTER_ETH_ZAP_ADDR" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  OWNER_CHECK2=$("$CAST" call "$MINTER_ETH_ZAP_ADDR" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  REFERRAL_CHECK2=$("$CAST" call "$MINTER_ETH_ZAP_ADDR" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR")
  
  if [[ "$MINTER_CHECK" == "$MINTER_ETH" ]]; then
    echo "  ✓ MINTER:   $MINTER_CHECK"
  else
    echo "  ✗ MINTER:   $MINTER_CHECK (expected: $MINTER_ETH)"
  fi
  
  if [[ "$OWNER_CHECK2" != "ERROR" ]]; then
    echo "  ✓ Owner:    $OWNER_CHECK2"
  else
    echo "  ✗ Owner:    Failed to read"
  fi
  
  if [[ "$REFERRAL_CHECK2" == "$REFERRAL_ETH" ]]; then
    echo "  ✓ Referral: $REFERRAL_CHECK2"
  else
    echo "  ✗ Referral: $REFERRAL_CHECK2 (expected: $REFERRAL_ETH)"
  fi
  
  echo ""
  echo "  Note: MinterETHZap_v2 functions require minWstEthOut parameter for slippage protection:"
  echo "    - zapEthToPegged(receiver, minPeggedOut, minWstEthOut)"
  echo "    - zapEthToLeveraged(receiver, minLeveragedOut, minWstEthOut)"
  echo "    - zapStEthToPegged(stEthAmount, receiver, minPeggedOut, minWstEthOut)"
  echo "    - zapStEthToLeveraged(stEthAmount, receiver, minLeveragedOut, minWstEthOut)"
fi

echo ""
echo "✅ Deployment complete!"

