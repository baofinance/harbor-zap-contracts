#!/usr/bin/env bash

set -euo pipefail

# Comprehensive script to deposit ETH, stETH, or wstETH to Genesis
# Usage:
#   DEPOSIT_TYPE=eth DEPOSIT_AMOUNT=10000000000000000000 bash script/deposit-all-types.sh
#   DEPOSIT_TYPE=steth DEPOSIT_AMOUNT=10000000000000000000 bash script/deposit-all-types.sh
#   DEPOSIT_TYPE=wsteth DEPOSIT_AMOUNT=10000000000000000000 bash script/deposit-all-types.sh

# Load environment variables from .env.local if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"
if [[ -f .env.local ]]; then
  set -a
  source .env.local
  set +a
fi

CAST=${CAST:-$HOME/.foundry/bin/cast}

# Load required variables from .env.local (no hardcoded defaults)
RPC_URL=${RPC_URL}
PRIVATE_KEY=${PRIVATE_KEY}
WALLET=${WALLET}
ZAP_CONTRACT=${ZAP_CONTRACT}
GENESIS_CONTRACT=${GENESIS_CONTRACT}
DEPOSIT_TYPE=${DEPOSIT_TYPE:-eth}  # eth, steth, or wsteth
DEPOSIT_AMOUNT=${DEPOSIT_AMOUNT:-10000000000000000000}  # Default: 10 ETH

# Validate required variables
if [[ -z "${RPC_URL:-}" ]]; then
  echo "ERROR: RPC_URL must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
  echo "ERROR: PRIVATE_KEY must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${WALLET:-}" ]]; then
  echo "ERROR: WALLET must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${ZAP_CONTRACT:-}" ]]; then
  echo "ERROR: ZAP_CONTRACT must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${GENESIS_CONTRACT:-}" ]]; then
  echo "ERROR: GENESIS_CONTRACT must be set in .env.local or as environment variable"
  exit 1
fi

# Token addresses - must be set in .env.local
STETH=${STETH}
WSTETH=${WSTETH}
REFERRAL=${REFERRAL_ETH:-0x0000000000000000000000000000000000000000}

# Validate required token addresses
if [[ -z "${STETH:-}" ]]; then
  echo "ERROR: STETH must be set in .env.local or as environment variable"
  exit 1
fi

if [[ -z "${WSTETH:-}" ]]; then
  echo "ERROR: WSTETH must be set in .env.local or as environment variable"
  exit 1
fi

echo "=========================================="
echo "Deposit to Genesis - All Types Supported"
echo "=========================================="
echo ""
echo "Wallet:        $WALLET"
echo "Zap Contract:  $ZAP_CONTRACT"
echo "Genesis:       $GENESIS_CONTRACT"
echo "Deposit Type:  $DEPOSIT_TYPE"
echo "Amount:        $("$CAST" --to-unit "$DEPOSIT_AMOUNT" ether) $DEPOSIT_TYPE"
echo ""

# Validate deposit type
if [[ "$DEPOSIT_TYPE" != "eth" ]] && [[ "$DEPOSIT_TYPE" != "steth" ]] && [[ "$DEPOSIT_TYPE" != "wsteth" ]]; then
  echo "ERROR: DEPOSIT_TYPE must be 'eth', 'steth', or 'wsteth'"
  exit 1
fi

# Step 1: Check balances BEFORE
echo "=== STEP 1: Balances BEFORE ==="
WALLET_ETH_BEFORE=$("$CAST" balance "$WALLET" --rpc-url "$RPC_URL")
WALLET_STETH_BEFORE=$("$CAST" call "$STETH" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
WALLET_WSTETH_BEFORE=$("$CAST" call "$WSTETH" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
WALLET_GENESIS_BEFORE=$("$CAST" call "$GENESIS_CONTRACT" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
GENESIS_WSTETH_BEFORE=$("$CAST" call "$WSTETH" "balanceOf(address)(uint256)" "$GENESIS_CONTRACT" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")

echo "  Wallet ETH:           $("$CAST" --to-unit "$WALLET_ETH_BEFORE" ether) ETH"
echo "  Wallet stETH:          $("$CAST" --to-unit "$WALLET_STETH_BEFORE" ether) stETH"
echo "  Wallet wstETH:         $("$CAST" --to-unit "$WALLET_WSTETH_BEFORE" ether) wstETH"
echo "  Wallet Genesis shares: $("$CAST" --to-unit "$WALLET_GENESIS_BEFORE" ether) shares"
echo "  Genesis wstETH:        $("$CAST" --to-unit "$GENESIS_WSTETH_BEFORE" ether) wstETH"
echo ""

# Handle different deposit types
if [[ "$DEPOSIT_TYPE" == "eth" ]]; then
  # ETH → Zap through GenesisETHZap contract
  echo "=== STEP 2: Zapping ETH through Zap Contract ==="
  
  # Get preview
  PREVIEW_OUT=$("$CAST" call "$ZAP_CONTRACT" "previewDepositETH(uint256)(uint256,uint256,uint256)" "$DEPOSIT_AMOUNT" --rpc-url "$RPC_URL")
  PREVIEW_SHARES=$(echo "$PREVIEW_OUT" | head -1 | awk '{print $1}')
  MIN_WSTETH_OUT=$(echo "$PREVIEW_SHARES * 99 / 100" | bc)
  
  echo "  Expected wstETH out:  $("$CAST" --to-unit "$PREVIEW_SHARES" ether) wstETH"
  echo "  Min wstETH (1% slippage): $("$CAST" --to-unit "$MIN_WSTETH_OUT" ether) wstETH"
  echo "  Calling: zapEth($WALLET, $MIN_WSTETH_OUT)"
  echo ""
  
  ZAP_OUT=$("$CAST" send "$ZAP_CONTRACT" "zapEth(address,uint256)" "$WALLET" "$MIN_WSTETH_OUT" \
    --value "$DEPOSIT_AMOUNT" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" 2>&1)
  
  TX_HASH=$(echo "$ZAP_OUT" | grep -oE "0x[a-fA-F0-9]{64}" | head -1)
  if [[ -n "$TX_HASH" ]]; then
    echo "  ✓ Transaction: $TX_HASH"
  else
    echo "  ✗ Failed:"
    echo "$ZAP_OUT"
    exit 1
  fi
  
elif [[ "$DEPOSIT_TYPE" == "steth" ]]; then
  # stETH → Zap through GenesisETHZap contract
  echo "=== STEP 2: Zapping stETH through Zap Contract ==="
  
  # Get preview
  PREVIEW_OUT=$("$CAST" call "$ZAP_CONTRACT" "previewDepositStETH(uint256)(uint256,uint256,uint256)" "$DEPOSIT_AMOUNT" --rpc-url "$RPC_URL")
  PREVIEW_SHARES=$(echo "$PREVIEW_OUT" | head -1 | awk '{print $1}')
  MIN_WSTETH_OUT=$(echo "$PREVIEW_SHARES * 99 / 100" | bc)
  
  echo "  Expected wstETH out:  $("$CAST" --to-unit "$PREVIEW_SHARES" ether) wstETH"
  echo "  Min wstETH (1% slippage): $("$CAST" --to-unit "$MIN_WSTETH_OUT" ether) wstETH"
  echo "  Approving zap contract..."
  
  # Approve zap contract
  APPROVE_OUT=$("$CAST" send "$STETH" "approve(address,uint256)" "$ZAP_CONTRACT" "$DEPOSIT_AMOUNT" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" 2>&1)
  
  sleep 2
  
  echo "  Calling: zapStEth($DEPOSIT_AMOUNT, $WALLET, $MIN_WSTETH_OUT)"
  echo ""
  
  ZAP_OUT=$("$CAST" send "$ZAP_CONTRACT" "zapStEth(uint256,address,uint256)" "$DEPOSIT_AMOUNT" "$WALLET" "$MIN_WSTETH_OUT" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" 2>&1)
  
  TX_HASH=$(echo "$ZAP_OUT" | grep -oE "0x[a-fA-F0-9]{64}" | head -1)
  if [[ -n "$TX_HASH" ]]; then
    echo "  ✓ Transaction: $TX_HASH"
  else
    echo "  ✗ Failed:"
    echo "$ZAP_OUT"
    exit 1
  fi
  
elif [[ "$DEPOSIT_TYPE" == "wsteth" ]]; then
  # wstETH → Direct deposit to Genesis contract
  echo "=== STEP 2: Depositing wstETH directly to Genesis ==="
  
  echo "  Approving Genesis contract..."
  
  # Approve Genesis contract
  APPROVE_OUT=$("$CAST" send "$WSTETH" "approve(address,uint256)" "$GENESIS_CONTRACT" "$DEPOSIT_AMOUNT" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" 2>&1)
  
  sleep 2
  
  echo "  Calling: Genesis.deposit($DEPOSIT_AMOUNT, $WALLET)"
  echo ""
  
  DEPOSIT_OUT=$("$CAST" send "$GENESIS_CONTRACT" "deposit(uint256,address)" "$DEPOSIT_AMOUNT" "$WALLET" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" 2>&1)
  
  TX_HASH=$(echo "$DEPOSIT_OUT" | grep -oE "0x[a-fA-F0-9]{64}" | head -1)
  if [[ -n "$TX_HASH" ]]; then
    echo "  ✓ Transaction: $TX_HASH"
  else
    echo "  ✗ Failed:"
    echo "$DEPOSIT_OUT"
    exit 1
  fi
fi

sleep 2

# Step 3: Check balances AFTER
echo ""
echo "=== STEP 3: Balances AFTER ==="
WALLET_ETH_AFTER=$("$CAST" balance "$WALLET" --rpc-url "$RPC_URL")
WALLET_STETH_AFTER=$("$CAST" call "$STETH" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
WALLET_WSTETH_AFTER=$("$CAST" call "$WSTETH" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
WALLET_GENESIS_AFTER=$("$CAST" call "$GENESIS_CONTRACT" "balanceOf(address)(uint256)" "$WALLET" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")
GENESIS_WSTETH_AFTER=$("$CAST" call "$WSTETH" "balanceOf(address)(uint256)" "$GENESIS_CONTRACT" --rpc-url "$RPC_URL" 2>/dev/null | head -1 | awk '{print $1}' || echo "0")

echo "  Wallet ETH:           $("$CAST" --to-unit "$WALLET_ETH_AFTER" ether) ETH"
echo "  Wallet stETH:          $("$CAST" --to-unit "$WALLET_STETH_AFTER" ether) stETH"
echo "  Wallet wstETH:         $("$CAST" --to-unit "$WALLET_WSTETH_AFTER" ether) wstETH"
echo "  Wallet Genesis shares: $("$CAST" --to-unit "$WALLET_GENESIS_AFTER" ether) shares"
echo "  Genesis wstETH:        $("$CAST" --to-unit "$GENESIS_WSTETH_AFTER" ether) wstETH"
echo ""

# Step 4: Summary
echo "=== STEP 4: Summary ==="
if [[ "$DEPOSIT_TYPE" == "eth" ]]; then
  ETH_SPENT=$(echo "scale=6; ($WALLET_ETH_BEFORE - $WALLET_ETH_AFTER) / 10^18" | bc)
  echo "  ETH spent:             $ETH_SPENT ETH"
elif [[ "$DEPOSIT_TYPE" == "steth" ]]; then
  STETH_SPENT=$(echo "scale=6; ($WALLET_STETH_BEFORE - $WALLET_STETH_AFTER) / 10^18" | bc)
  echo "  stETH spent:           $STETH_SPENT stETH"
elif [[ "$DEPOSIT_TYPE" == "wsteth" ]]; then
  WSTETH_SPENT=$(echo "scale=6; ($WALLET_WSTETH_BEFORE - $WALLET_WSTETH_AFTER) / 10^18" | bc)
  echo "  wstETH spent:          $WSTETH_SPENT wstETH"
fi

GENESIS_GAINED=$(echo "scale=6; ($WALLET_GENESIS_AFTER - $WALLET_GENESIS_BEFORE) / 10^18" | bc)
WSTETH_DEPOSITED=$(echo "scale=6; ($GENESIS_WSTETH_AFTER - $GENESIS_WSTETH_BEFORE) / 10^18" | bc)

echo "  Genesis shares gained: $GENESIS_GAINED shares"
echo "  wstETH deposited:       $WSTETH_DEPOSITED wstETH"
echo ""

echo "=========================================="
echo "✅ Deposit Complete!"
echo "=========================================="

