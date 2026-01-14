#!/usr/bin/env bash

set -euo pipefail

# Harbor Zap Contracts Verification Script
# Verifies all zap contracts from deployments/zap-contracts-latest.json

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

# Check if jq is available
if ! command -v jq &> /dev/null; then
  echo "❌ ERROR: jq is required but not installed"
  echo "   Install it via: brew install jq (macOS) or apt-get install jq (Linux)"
  exit 1
fi

# Check if ETHERSCAN_API_KEY is set
if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "❌ ERROR: ETHERSCAN_API_KEY is not set"
  echo "   Set it via: export ETHERSCAN_API_KEY='your_api_key'"
  echo "   Or add it to .env.local file"
  exit 1
fi

# Deployment file (default to latest.json, but allow override)
DEPLOYMENT_FILE=${DEPLOYMENT_FILE:-deployments/zap-contracts-latest.json}

if [[ ! -f "$DEPLOYMENT_FILE" ]]; then
  echo "❌ ERROR: Deployment file not found: $DEPLOYMENT_FILE"
  exit 1
fi

echo "=== VERIFYING ZAP CONTRACTS ON ETHERSCAN ==="
echo "Deployment file: $DEPLOYMENT_FILE"
echo ""

# Read deployment info
DEPLOYMENT_TIME=$(jq -r '.deployment_time // "unknown"' "$DEPLOYMENT_FILE")
CHAIN_ID=$(jq -r '.chain_id // "1"' "$DEPLOYMENT_FILE")
NETWORK=$(jq -r '.network // "mainnet"' "$DEPLOYMENT_FILE")

echo "Deployment info:"
echo "  Time: $DEPLOYMENT_TIME"
echo "  Chain ID: $CHAIN_ID"
echo "  Network: $NETWORK"
echo ""

COUNT=0
TOTAL=0
FAILED=0

# Count total contracts
TOTAL=$(($(jq '.genesis_zaps | length' "$DEPLOYMENT_FILE") + $(jq '.minter_zaps | length' "$DEPLOYMENT_FILE")))

echo "=== Verifying Genesis Zaps ==="
echo ""

# Verify GenesisUSDCZap_v2 contracts
for key in $(jq -r '.genesis_zaps | keys[]' "$DEPLOYMENT_FILE"); do
  contract=$(jq -r ".genesis_zaps[\"$key\"].contract" "$DEPLOYMENT_FILE")
  address=$(jq -r ".genesis_zaps[\"$key\"].address" "$DEPLOYMENT_FILE")
  genesis=$(jq -r ".genesis_zaps[\"$key\"].genesis" "$DEPLOYMENT_FILE")
  referral=$(jq -r ".genesis_zaps[\"$key\"].referral // empty" "$DEPLOYMENT_FILE")
  
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Genesis $key Zap..."
  echo "  Address: $address"
  echo "  Contract: $contract"
  
  if [[ "$contract" == "GenesisUSDCZap_v2" ]]; then
    # Constructor: (address genesis_)
    CONSTRUCTOR_ARGS=$("$CAST" abi-encode "constructor(address)" "$genesis")
    CONTRACT_PATH="src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2"
  elif [[ "$contract" == "GenesisETHZap_v3" ]]; then
    # Constructor: (address genesis_, address referral_)
    CONSTRUCTOR_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$genesis" "$referral")
    CONTRACT_PATH="src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3"
  else
    echo "  ✗ Unknown contract type: $contract"
    FAILED=$((FAILED + 1))
    echo ""
    continue
  fi
  
  if "$FORGE" verify-contract \
    "$address" \
    "$CONTRACT_PATH" \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$CONSTRUCTOR_ARGS" \
    --chain mainnet 2>&1; then
    echo "  ✓ Genesis $key Zap verified"
  else
    echo "  ✗ Genesis $key Zap verification failed"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "=== Verifying Minter Zaps ==="
echo ""

# Verify Minter contracts
for key in $(jq -r '.minter_zaps | keys[]' "$DEPLOYMENT_FILE"); do
  contract=$(jq -r ".minter_zaps[\"$key\"].contract" "$DEPLOYMENT_FILE")
  address=$(jq -r ".minter_zaps[\"$key\"].address" "$DEPLOYMENT_FILE")
  minter=$(jq -r ".minter_zaps[\"$key\"].minter" "$DEPLOYMENT_FILE")
  referral=$(jq -r ".minter_zaps[\"$key\"].referral // empty" "$DEPLOYMENT_FILE")
  
  COUNT=$((COUNT + 1))
  echo "$COUNT/$TOTAL Verifying Minter $key Zap..."
  echo "  Address: $address"
  echo "  Contract: $contract"
  
  if [[ "$contract" == "MinterUSDCZap_v2" ]]; then
    # Constructor: (address minter_)
    CONSTRUCTOR_ARGS=$("$CAST" abi-encode "constructor(address)" "$minter")
    CONTRACT_PATH="src/zap/MinterUSDCZap_v2.sol:MinterUSDCZapV2"
  elif [[ "$contract" == "MinterETHZap_v2" ]]; then
    # Constructor: (address minter_, address referral_)
    CONSTRUCTOR_ARGS=$("$CAST" abi-encode "constructor(address,address)" "$minter" "$referral")
    CONTRACT_PATH="src/zap/MinterETHZap_v2.sol:MinterETHZapV2"
  else
    echo "  ✗ Unknown contract type: $contract"
    FAILED=$((FAILED + 1))
    echo ""
    continue
  fi
  
  if "$FORGE" verify-contract \
    "$address" \
    "$CONTRACT_PATH" \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$CONSTRUCTOR_ARGS" \
    --chain mainnet 2>&1; then
    echo "  ✓ Minter $key Zap verified"
  else
    echo "  ✗ Minter $key Zap verification failed"
    FAILED=$((FAILED + 1))
  fi
  echo ""
done

echo "=== Verification Summary ==="
echo "Total contracts: $TOTAL"
echo "Verified: $((TOTAL - FAILED))"
echo "Failed: $FAILED"
echo ""

if [[ $FAILED -eq 0 ]]; then
  echo "✅ All contracts verified successfully!"
  exit 0
else
  echo "⚠️  Some contracts failed verification. Check the output above for details."
  exit 1
fi

