#!/usr/bin/env bash

set -euo pipefail

# Harbor ETH/wstETH Zap Contracts Deployment Script v2
# Deploys GenesisETHZap_v2 and MinterETHZap_v2

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
# Can be overridden via environment variables if needed
GENESIS_ETH=${GENESIS_ETH:-0x59C2776E88fF80841c88138a2CD0f375F544EeaE}
MINTER_ETH=${MINTER_ETH:-0x6d64EC8B95Eeab780745d3bDF5BB06D08e38cC29}

# Lido referral address (defaults to Harbor's referral)
REFERRAL_ETH=${REFERRAL_ETH:-0x3dFc49e5112005179Da613BdE5973229082dAc35}

echo "=== Deploying ETH/wstETH Zap Contracts ==="
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
    --constructor-args $constructor_args 2>&1)
  
  if [[ $? -ne 0 ]] || ! echo "$DEPLOY_OUT" | grep -q "Contract:"; then
    echo "ERROR: $contract_name deployment failed!" >&2
    echo "Error output:" >&2
    echo "$DEPLOY_OUT" | grep -E "(Error|error|revert|Revert)" | head -5 >&2
    return 1
  fi
  
  # Extract deployed address from transaction output
  # The address is computed from the deployer address and nonce
  DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY" 2>/dev/null || echo "")
  if [[ -n "$DEPLOYER" ]]; then
    NONCE=$("$CAST" nonce "$DEPLOYER" --rpc-url "$RPC_URL" 2>/dev/null || echo "0")
    # Compute CREATE address: keccak256(rlp([sender, nonce]))
    # For simplicity, we'll get it from the transaction receipt if available
    echo "$DEPLOY_OUT" | grep -oE "0x[a-fA-F0-9]{40}" | head -1 || echo "Address computed from deployer + nonce"
  else
    echo "Deployment prepared (dry run)"
  fi
}

# 1. Deploy GenesisETHZap_v2
# Constructor: (address genesis_, address referral_)
echo "1. Deploying GenesisETHZap_v2..."
GENESIS_ETH_ZAP_OUT=$("$FORGE" create src/minter/GenesisETHZap_v2.sol:GenesisETHZapV2 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  --constructor-args "$GENESIS_ETH" "$REFERRAL_ETH" 2>&1)

if echo "$GENESIS_ETH_ZAP_OUT" | grep -q "Deployed to:"; then
  GENESIS_ETH_ZAP_ADDR=$(echo "$GENESIS_ETH_ZAP_OUT" | grep -oE "Deployed to: 0x[a-fA-F0-9]{40}" | awk '{print $3}')
  echo "  ✓ GenesisETHZap_v2 deployed to: $GENESIS_ETH_ZAP_ADDR"
elif echo "$GENESIS_ETH_ZAP_OUT" | grep -q "Contract:"; then
  echo "  ✓ GenesisETHZap_v2 deployment prepared"
else
  echo "  ✗ GenesisETHZap_v2 deployment failed"
  echo "$GENESIS_ETH_ZAP_OUT" | grep -E "(Error|error|revert)" | head -3
  exit 1
fi

# 2. Deploy MinterETHZap_v2
# Constructor: (address minter_, address referral_)
echo "2. Deploying MinterETHZap_v2..."
MINTER_ETH_ZAP_OUT=$("$FORGE" create src/minter/MinterETHZap_v2.sol:MinterETHZapV2 \
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
  
  # Verify GenesisETHZap_v2
  echo "GenesisETHZap_v2 ($GENESIS_ETH_ZAP_ADDR):"
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
fi

echo ""
echo "✅ Deployment complete!"

