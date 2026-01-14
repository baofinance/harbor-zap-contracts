#!/usr/bin/env bash

set -euo pipefail

# Harbor Zap Contracts Deployment Script v3
# Deploys zap contracts for all 5 asset pairs:
# - BTC fxUSD, BTC stETH, ETH fxUSD, EUR fxUSD, GOLD fxUSD
#
# Usage:
#   Deploy:     ./script/deploy-zaps.sh
#   Verify:     MODE=verify ./script/deploy-zaps.sh
#   Verify only: MODE=verify-only ./script/deploy-zaps.sh

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

# Mode: deploy (default), verify, verify-only
MODE=${MODE:-deploy}

# Load required variables from .env.local (no hardcoded defaults)
RPC_URL=${RPC_URL}
PRIVATE_KEY=${PRIVATE_KEY}
OWNER=${OWNER}

# Allow manual override of deployed contract addresses for verification
GENESIS_BTC_FXUSD_ZAP=${GENESIS_BTC_FXUSD_ZAP:-}
GENESIS_BTC_STETH_ZAP=${GENESIS_BTC_STETH_ZAP:-}
GENESIS_ETH_FXUSD_ZAP=${GENESIS_ETH_FXUSD_ZAP:-}
GENESIS_EUR_FXUSD_ZAP=${GENESIS_EUR_FXUSD_ZAP:-}
GENESIS_GOLD_FXUSD_ZAP=${GENESIS_GOLD_FXUSD_ZAP:-}
MINTER_BTC_FXUSD_ZAP=${MINTER_BTC_FXUSD_ZAP:-}
MINTER_BTC_STETH_ZAP=${MINTER_BTC_STETH_ZAP:-}
MINTER_ETH_FXUSD_ZAP=${MINTER_ETH_FXUSD_ZAP:-}
MINTER_EUR_FXUSD_ZAP=${MINTER_EUR_FXUSD_ZAP:-}
MINTER_GOLD_FXUSD_ZAP=${MINTER_GOLD_FXUSD_ZAP:-}

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

# Contract addresses - must be set in .env.local
# BTC fxUSD
GENESIS_BTC_FXUSD=${GENESIS_BTC_FXUSD}
MINTER_BTC_FXUSD=${MINTER_BTC_FXUSD}

# BTC stETH
GENESIS_BTC_STETH=${GENESIS_BTC_STETH}
MINTER_BTC_STETH=${MINTER_BTC_STETH}

# ETH fxUSD
GENESIS_ETH_FXUSD=${GENESIS_ETH_FXUSD}
MINTER_ETH_FXUSD=${MINTER_ETH_FXUSD}

# EUR fxUSD
GENESIS_EUR_FXUSD=${GENESIS_EUR_FXUSD}
MINTER_EUR_FXUSD=${MINTER_EUR_FXUSD}

# GOLD fxUSD
GENESIS_GOLD_FXUSD=${GENESIS_GOLD_FXUSD}
MINTER_GOLD_FXUSD=${MINTER_GOLD_FXUSD}

# Validate required contract addresses
declare -a REQUIRED_VARS=(
  "GENESIS_BTC_FXUSD"
  "MINTER_BTC_FXUSD"
  "GENESIS_BTC_STETH"
  "MINTER_BTC_STETH"
  "GENESIS_ETH_FXUSD"
  "MINTER_ETH_FXUSD"
  "GENESIS_EUR_FXUSD"
  "MINTER_EUR_FXUSD"
  "GENESIS_GOLD_FXUSD"
  "MINTER_GOLD_FXUSD"
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: $var must be set in .env.local or as environment variable"
    exit 1
  fi
  
  if [[ "${!var}" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "ERROR: $var must be set to a valid contract address"
    exit 1
  fi
done

# Lido referral address (optional, can be set in .env.local)
REFERRAL_ETH=${REFERRAL_ETH:-0x3dFc49e5112005179Da613BdE5973229082dAc35}

# Handle verify-only mode (skip deployment, only verify)
if [[ "$MODE" == "verify-only" ]]; then
  # Check if ETHERSCAN_API_KEY is set
  if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
    echo "❌ ERROR: ETHERSCAN_API_KEY is not set"
    echo "   Set it via: export ETHERSCAN_API_KEY='your_api_key'"
    echo "   Or add it to .env.local file"
    exit 1
  fi
  
  # Validate that contract addresses are set
  declare -a REQUIRED_ZAPS=(
    "GENESIS_BTC_FXUSD_ZAP"
    "GENESIS_BTC_STETH_ZAP"
    "GENESIS_ETH_FXUSD_ZAP"
    "GENESIS_EUR_FXUSD_ZAP"
    "GENESIS_GOLD_FXUSD_ZAP"
    "MINTER_BTC_FXUSD_ZAP"
    "MINTER_BTC_STETH_ZAP"
    "MINTER_ETH_FXUSD_ZAP"
    "MINTER_EUR_FXUSD_ZAP"
    "MINTER_GOLD_FXUSD_ZAP"
  )
  
  for var in "${REQUIRED_ZAPS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "❌ ERROR: $var must be set for verification"
      echo "   Set it via: export $var='0x...'"
      echo "   Or add it to .env.local file"
      exit 1
    fi
  done
  
  echo "=== VERIFYING CONTRACTS ON ETHERSCAN ==="
  echo ""
  
  COUNT=0
  TOTAL=10
  
  # Verify GenesisUSDCZap_v2 contracts (4 contracts)
  echo "Verifying GenesisUSDCZap_v2 contracts..."
  
  # BTC fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis BTC fxUSD Zap..."
  GENESIS_BTC_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_BTC_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_BTC_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_BTC_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis BTC fxUSD Zap verified" || echo "  ✗ Genesis BTC fxUSD Zap verification failed"
  echo ""
  
  # ETH fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis ETH fxUSD Zap..."
  GENESIS_ETH_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_ETH_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_ETH_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_ETH_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis ETH fxUSD Zap verified" || echo "  ✗ Genesis ETH fxUSD Zap verification failed"
  echo ""
  
  # EUR fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis EUR fxUSD Zap..."
  GENESIS_EUR_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_EUR_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_EUR_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_EUR_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis EUR fxUSD Zap verified" || echo "  ✗ Genesis EUR fxUSD Zap verification failed"
  echo ""
  
  # GOLD fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis GOLD fxUSD Zap..."
  GENESIS_GOLD_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_GOLD_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_GOLD_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_GOLD_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis GOLD fxUSD Zap verified" || echo "  ✗ Genesis GOLD fxUSD Zap verification failed"
  echo ""
  
  # Verify GenesisETHZap_v3 (1 contract)
  echo "Verifying GenesisETHZap_v3 contract..."
  
  # BTC stETH
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis BTC stETH Zap..."
  GENESIS_BTC_STETH_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$GENESIS_BTC_STETH" "$REFERRAL_ETH")
  "$FORGE" verify-contract \
    "$GENESIS_BTC_STETH_ZAP" \
    src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_BTC_STETH_ARGS" \
    --chain mainnet && echo "  ✓ Genesis BTC stETH Zap verified" || echo "  ✗ Genesis BTC stETH Zap verification failed"
  echo ""
  
  # Verify MinterUSDCZap_v2 contracts (4 contracts)
  echo "Verifying MinterUSDCZap_v2 contracts..."
  
  # BTC fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter BTC fxUSD Zap..."
  MINTER_BTC_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_BTC_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_BTC_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_BTC_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter BTC fxUSD Zap verified" || echo "  ✗ Minter BTC fxUSD Zap verification failed"
  echo ""
  
  # ETH fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter ETH fxUSD Zap..."
  MINTER_ETH_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_ETH_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_ETH_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_ETH_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter ETH fxUSD Zap verified" || echo "  ✗ Minter ETH fxUSD Zap verification failed"
  echo ""
  
  # EUR fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter EUR fxUSD Zap..."
  MINTER_EUR_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_EUR_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_EUR_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_EUR_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter EUR fxUSD Zap verified" || echo "  ✗ Minter EUR fxUSD Zap verification failed"
  echo ""
  
  # GOLD fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter GOLD fxUSD Zap..."
  MINTER_GOLD_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_GOLD_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_GOLD_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_GOLD_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter GOLD fxUSD Zap verified" || echo "  ✗ Minter GOLD fxUSD Zap verification failed"
  echo ""
  
  # Verify MinterETHZap_v2 (1 contract)
  echo "Verifying MinterETHZap_v2 contract..."
  
  # BTC stETH
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter BTC stETH Zap..."
  MINTER_BTC_STETH_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$MINTER_BTC_STETH" "$REFERRAL_ETH")
  "$FORGE" verify-contract \
    "$MINTER_BTC_STETH_ZAP" \
    src/zap/MinterETHZap_v2.sol:MinterETHZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_BTC_STETH_ARGS" \
    --chain mainnet && echo "  ✓ Minter BTC stETH Zap verified" || echo "  ✗ Minter BTC stETH Zap verification failed"
  echo ""
  
  echo "✅ Verification complete!"
  exit 0
fi

# Validate required variables for deployment
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

echo "=== Deploying 10 Zap Contracts ==="
echo ""

# Helper function to deploy zap contract
deploy_zap() {
  local contract_name=$1
  local contract_path=$2
  local constructor_args=$3
  
  echo "Deploying $contract_name..." >&2
  
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
  echo "  ✓ $contract_name: $DEPLOYED" >&2
  echo "$DEPLOYED"
}

# ============================================================
# GENESIS ZAPS (6 contracts)
# ============================================================

# BTC fxUSD - uses GenesisUSDCZap_v2 (fxSAVE)
GENESIS_BTC_FXUSD_ZAP=$(deploy_zap "GenesisBTCfxUSDZap_v2" \
  "src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2" \
  "$GENESIS_BTC_FXUSD")

# BTC stETH - uses GenesisETHZap_v3 (wstETH)
GENESIS_BTC_STETH_ZAP=$(deploy_zap "GenesisBTCstETHZap_v3" \
  "src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3" \
  "$GENESIS_BTC_STETH $REFERRAL_ETH")

# ETH fxUSD - uses GenesisUSDCZap_v2 (fxSAVE)
GENESIS_ETH_FXUSD_ZAP=$(deploy_zap "GenesisETHfxUSDZap_v2" \
  "src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2" \
  "$GENESIS_ETH_FXUSD")

# EUR fxUSD - uses GenesisUSDCZap_v2 (fxSAVE)
GENESIS_EUR_FXUSD_ZAP=$(deploy_zap "GenesisEURfxUSDZap_v2" \
  "src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2" \
  "$GENESIS_EUR_FXUSD")

# GOLD fxUSD - uses GenesisUSDCZap_v2 (fxSAVE)
GENESIS_GOLD_FXUSD_ZAP=$(deploy_zap "GenesisGOLDfxUSDZap_v2" \
  "src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2" \
  "$GENESIS_GOLD_FXUSD")

echo ""

# ============================================================
# MINTER ZAPS (5 contracts)
# ============================================================

# BTC fxUSD - uses MinterUSDCZap_v2 (fxSAVE)
MINTER_BTC_FXUSD_ZAP=$(deploy_zap "MinterBTCfxUSDZap_v2" \
  "src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2" \
  "$MINTER_BTC_FXUSD")

# BTC stETH - uses MinterETHZap_v2 (wstETH)
MINTER_BTC_STETH_ZAP=$(deploy_zap "MinterBTCstETHZap_v2" \
  "src/zap/MinterETHZap_v2.sol:MinterETHZapV2" \
  "$MINTER_BTC_STETH $REFERRAL_ETH")

# ETH fxUSD - uses MinterUSDCZap_v2 (fxSAVE)
MINTER_ETH_FXUSD_ZAP=$(deploy_zap "MinterETHfxUSDZap_v2" \
  "src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2" \
  "$MINTER_ETH_FXUSD")

# EUR fxUSD - uses MinterUSDCZap_v2 (fxSAVE)
MINTER_EUR_FXUSD_ZAP=$(deploy_zap "MinterEURfxUSDZap_v2" \
  "src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2" \
  "$MINTER_EUR_FXUSD")

# GOLD fxUSD - uses MinterUSDCZap_v2 (fxSAVE)
MINTER_GOLD_FXUSD_ZAP=$(deploy_zap "MinterGOLDfxUSDZap_v2" \
  "src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2" \
  "$MINTER_GOLD_FXUSD")

echo ""
echo "=== DEPLOYMENT SUMMARY ==="
echo ""
echo "GENESIS ZAPS (5 contracts):"
echo "  BTC fxUSD:  $GENESIS_BTC_FXUSD_ZAP"
echo "  BTC stETH:  $GENESIS_BTC_STETH_ZAP"
echo "  ETH fxUSD: $GENESIS_ETH_FXUSD_ZAP"
echo "  EUR fxUSD: $GENESIS_EUR_FXUSD_ZAP"
echo "  GOLD fxUSD: $GENESIS_GOLD_FXUSD_ZAP"
echo ""
echo "MINTER ZAPS (5 contracts):"
echo "  BTC fxUSD:  $MINTER_BTC_FXUSD_ZAP"
echo "  BTC stETH:  $MINTER_BTC_STETH_ZAP"
echo "  ETH fxUSD:  $MINTER_ETH_FXUSD_ZAP"
echo "  EUR fxUSD:  $MINTER_EUR_FXUSD_ZAP"
echo "  GOLD fxUSD: $MINTER_GOLD_FXUSD_ZAP"
echo ""

# Verify deployments
echo "=== VERIFICATION ==="
echo ""

# Check owners
echo "Checking owners..."
echo -n "  Genesis BTC fxUSD owner:  "
"$CAST" call "$GENESIS_BTC_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis BTC stETH owner:  "
"$CAST" call "$GENESIS_BTC_STETH_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis ETH fxUSD owner:  "
"$CAST" call "$GENESIS_ETH_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis EUR fxUSD owner:  "
"$CAST" call "$GENESIS_EUR_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis GOLD fxUSD owner: "
"$CAST" call "$GENESIS_GOLD_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter BTC fxUSD owner:   "
"$CAST" call "$MINTER_BTC_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter BTC stETH owner:   "
"$CAST" call "$MINTER_BTC_STETH_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter ETH fxUSD owner:   "
"$CAST" call "$MINTER_ETH_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter EUR fxUSD owner:   "
"$CAST" call "$MINTER_EUR_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter GOLD fxUSD owner:  "
"$CAST" call "$MINTER_GOLD_FXUSD_ZAP" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""

# Check linked contracts
echo "Checking linked contracts..."
echo -n "  Genesis BTC fxUSD GENESIS:  "
"$CAST" call "$GENESIS_BTC_FXUSD_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis BTC stETH GENESIS:  "
"$CAST" call "$GENESIS_BTC_STETH_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis ETH fxUSD GENESIS:  "
"$CAST" call "$GENESIS_ETH_FXUSD_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis EUR fxUSD GENESIS:  "
"$CAST" call "$GENESIS_EUR_FXUSD_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Genesis GOLD fxUSD GENESIS: "
"$CAST" call "$GENESIS_GOLD_FXUSD_ZAP" "GENESIS()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter BTC fxUSD MINTER:   "
"$CAST" call "$MINTER_BTC_FXUSD_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter BTC stETH MINTER:   "
"$CAST" call "$MINTER_BTC_STETH_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter ETH fxUSD MINTER:   "
"$CAST" call "$MINTER_ETH_FXUSD_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter EUR fxUSD MINTER:   "
"$CAST" call "$MINTER_EUR_FXUSD_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter GOLD fxUSD MINTER:  "
"$CAST" call "$MINTER_GOLD_FXUSD_ZAP" "MINTER()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""

# Check referral (only for stETH zaps)
echo "Checking Lido referral (stETH zaps only)..."
echo -n "  Genesis BTC stETH referral: "
"$CAST" call "$GENESIS_BTC_STETH_ZAP" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo -n "  Minter BTC stETH referral: "
"$CAST" call "$MINTER_BTC_STETH_ZAP" "referral()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "ERROR"

echo ""
echo "✅ Deployment complete!"
echo ""

# Save deployment addresses to file
DEPLOYMENT_FILE="deployments/zap-contracts-$(date +%Y%m%d-%H%M%S).json"
mkdir -p deployments

cat > "$DEPLOYMENT_FILE" <<EOF
{
  "deployment_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "chain_id": "$CHAIN_ID",
  "network": "mainnet",
  "genesis_zaps": {
    "BTC_fxUSD": {
      "address": "$GENESIS_BTC_FXUSD_ZAP",
      "contract": "GenesisUSDCZap_v2",
      "genesis": "$GENESIS_BTC_FXUSD"
    },
    "BTC_stETH": {
      "address": "$GENESIS_BTC_STETH_ZAP",
      "contract": "GenesisETHZap_v3",
      "genesis": "$GENESIS_BTC_STETH",
      "referral": "$REFERRAL_ETH"
    },
    "ETH_fxUSD": {
      "address": "$GENESIS_ETH_FXUSD_ZAP",
      "contract": "GenesisUSDCZap_v2",
      "genesis": "$GENESIS_ETH_FXUSD"
    },
    "EUR_fxUSD": {
      "address": "$GENESIS_EUR_FXUSD_ZAP",
      "contract": "GenesisUSDCZap_v2",
      "genesis": "$GENESIS_EUR_FXUSD"
    },
    "GOLD_fxUSD": {
      "address": "$GENESIS_GOLD_FXUSD_ZAP",
      "contract": "GenesisUSDCZap_v2",
      "genesis": "$GENESIS_GOLD_FXUSD"
    }
  },
  "minter_zaps": {
    "BTC_fxUSD": {
      "address": "$MINTER_BTC_FXUSD_ZAP",
      "contract": "MinterUSDCZap_v2",
      "minter": "$MINTER_BTC_FXUSD"
    },
    "BTC_stETH": {
      "address": "$MINTER_BTC_STETH_ZAP",
      "contract": "MinterETHZap_v2",
      "minter": "$MINTER_BTC_STETH",
      "referral": "$REFERRAL_ETH"
    },
    "ETH_fxUSD": {
      "address": "$MINTER_ETH_FXUSD_ZAP",
      "contract": "MinterUSDCZap_v2",
      "minter": "$MINTER_ETH_FXUSD"
    },
    "EUR_fxUSD": {
      "address": "$MINTER_EUR_FXUSD_ZAP",
      "contract": "MinterUSDCZap_v2",
      "minter": "$MINTER_EUR_FXUSD"
    },
    "GOLD_fxUSD": {
      "address": "$MINTER_GOLD_FXUSD_ZAP",
      "contract": "MinterUSDCZap_v2",
      "minter": "$MINTER_GOLD_FXUSD"
    }
  }
}
EOF

# Also save as latest.json for easy reference
LATEST_FILE="deployments/latest.json"
cp "$DEPLOYMENT_FILE" "$LATEST_FILE"

echo "📄 Deployment addresses saved to:"
echo "   - $DEPLOYMENT_FILE"
echo "   - $LATEST_FILE (latest)"
echo ""

# Run verification if MODE=verify and ETHERSCAN_API_KEY is set
if [[ "$MODE" == "verify" ]] && [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "=== Running Verification ==="
  echo ""
  
  COUNT=0
  TOTAL=10
  
  # Verify GenesisUSDCZap_v2 contracts (4 contracts)
  echo "Verifying GenesisUSDCZap_v2 contracts..."
  
  # BTC fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis BTC fxUSD Zap..."
  GENESIS_BTC_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_BTC_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_BTC_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_BTC_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis BTC fxUSD Zap verified" || echo "  ✗ Genesis BTC fxUSD Zap verification failed"
  echo ""
  
  # ETH fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis ETH fxUSD Zap..."
  GENESIS_ETH_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_ETH_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_ETH_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_ETH_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis ETH fxUSD Zap verified" || echo "  ✗ Genesis ETH fxUSD Zap verification failed"
  echo ""
  
  # EUR fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis EUR fxUSD Zap..."
  GENESIS_EUR_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_EUR_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_EUR_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_EUR_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis EUR fxUSD Zap verified" || echo "  ✗ Genesis EUR fxUSD Zap verification failed"
  echo ""
  
  # GOLD fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis GOLD fxUSD Zap..."
  GENESIS_GOLD_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$GENESIS_GOLD_FXUSD")
  "$FORGE" verify-contract \
    "$GENESIS_GOLD_FXUSD_ZAP" \
    src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_GOLD_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Genesis GOLD fxUSD Zap verified" || echo "  ✗ Genesis GOLD fxUSD Zap verification failed"
  echo ""
  
  # Verify GenesisETHZap_v3 (1 contract)
  echo "Verifying GenesisETHZap_v3 contract..."
  
  # BTC stETH
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis BTC stETH Zap..."
  GENESIS_BTC_STETH_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$GENESIS_BTC_STETH" "$REFERRAL_ETH")
  "$FORGE" verify-contract \
    "$GENESIS_BTC_STETH_ZAP" \
    src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$GENESIS_BTC_STETH_ARGS" \
    --chain mainnet && echo "  ✓ Genesis BTC stETH Zap verified" || echo "  ✗ Genesis BTC stETH Zap verification failed"
  echo ""
  
  # Verify MinterUSDCZap_v2 contracts (4 contracts)
  echo "Verifying MinterUSDCZap_v2 contracts..."
  
  # BTC fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter BTC fxUSD Zap..."
  MINTER_BTC_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_BTC_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_BTC_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_BTC_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter BTC fxUSD Zap verified" || echo "  ✗ Minter BTC fxUSD Zap verification failed"
  echo ""
  
  # ETH fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter ETH fxUSD Zap..."
  MINTER_ETH_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_ETH_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_ETH_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_ETH_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter ETH fxUSD Zap verified" || echo "  ✗ Minter ETH fxUSD Zap verification failed"
  echo ""
  
  # EUR fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter EUR fxUSD Zap..."
  MINTER_EUR_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_EUR_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_EUR_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_EUR_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter EUR fxUSD Zap verified" || echo "  ✗ Minter EUR fxUSD Zap verification failed"
  echo ""
  
  # GOLD fxUSD
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter GOLD fxUSD Zap..."
  MINTER_GOLD_FXUSD_ARGS=$("$CAST" abi-encode "constructor(address)" "$MINTER_GOLD_FXUSD")
  "$FORGE" verify-contract \
    "$MINTER_GOLD_FXUSD_ZAP" \
    src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_GOLD_FXUSD_ARGS" \
    --chain mainnet && echo "  ✓ Minter GOLD fxUSD Zap verified" || echo "  ✗ Minter GOLD fxUSD Zap verification failed"
  echo ""
  
  # Verify MinterETHZap_v2 (1 contract)
  echo "Verifying MinterETHZap_v2 contract..."
  
  # BTC stETH
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter BTC stETH Zap..."
  MINTER_BTC_STETH_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$MINTER_BTC_STETH" "$REFERRAL_ETH")
  "$FORGE" verify-contract \
    "$MINTER_BTC_STETH_ZAP" \
    src/zap/MinterETHZap_v2.sol:MinterETHZapV2 \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$MINTER_BTC_STETH_ARGS" \
    --chain mainnet && echo "  ✓ Minter BTC stETH Zap verified" || echo "  ✗ Minter BTC stETH Zap verification failed"
  echo ""
  
  echo "✅ Verification complete!"
  echo ""
fi

echo ""
echo "Next steps:"
echo "  1. Transfer ownership of all zap contracts to desired owner:"
echo ""
echo "     # Genesis zaps"
echo "     cast send $GENESIS_BTC_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $GENESIS_BTC_STETH_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $GENESIS_ETH_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $GENESIS_EUR_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $GENESIS_GOLD_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo ""
echo "     # Minter zaps"
echo "     cast send $MINTER_BTC_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_BTC_STETH_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_ETH_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_EUR_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_GOLD_FXUSD_ZAP \"transferOwnership(address)\" <NEW_OWNER> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo ""
echo "  2. (Optional) Update Lido referral for stETH zaps:"
echo "     cast send $GENESIS_BTC_STETH_ZAP \"setReferral(address)\" <NEW_REFERRAL> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo "     cast send $MINTER_BTC_STETH_ZAP \"setReferral(address)\" <NEW_REFERRAL> --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
echo ""
echo "  3. Verify contracts on Etherscan:"
echo "     # Set deployed addresses and API key, then run:"
echo "     export GENESIS_BTC_FXUSD_ZAP=$GENESIS_BTC_FXUSD_ZAP"
echo "     export GENESIS_BTC_STETH_ZAP=$GENESIS_BTC_STETH_ZAP"
echo "     export GENESIS_ETH_FXUSD_ZAP=$GENESIS_ETH_FXUSD_ZAP"
echo "     export GENESIS_EUR_FXUSD_ZAP=$GENESIS_EUR_FXUSD_ZAP"
echo "     export GENESIS_GOLD_FXUSD_ZAP=$GENESIS_GOLD_FXUSD_ZAP"
echo "     export MINTER_BTC_FXUSD_ZAP=$MINTER_BTC_FXUSD_ZAP"
echo "     export MINTER_BTC_STETH_ZAP=$MINTER_BTC_STETH_ZAP"
echo "     export MINTER_ETH_FXUSD_ZAP=$MINTER_ETH_FXUSD_ZAP"
echo "     export MINTER_EUR_FXUSD_ZAP=$MINTER_EUR_FXUSD_ZAP"
echo "     export MINTER_GOLD_FXUSD_ZAP=$MINTER_GOLD_FXUSD_ZAP"
echo "     export ETHERSCAN_API_KEY=your_api_key"
echo "     MODE=verify-only ./script/deploy-zaps.sh"
echo ""
echo "     Or deploy and verify in one go:"
echo "     MODE=verify ./script/deploy-zaps.sh"
