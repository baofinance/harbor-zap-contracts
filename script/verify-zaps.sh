#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

FORGE=${FORGE:-$HOME/.foundry/bin/forge}
CAST=${CAST:-$HOME/.foundry/bin/cast}

if [[ -f "$ROOT_DIR/script/_load-env.sh" ]]; then
  source "$ROOT_DIR/script/_load-env.sh"
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

if [[ -z "${MAINNET_RPC_URL:-}" ]]; then
  echo "❌ ERROR: MAINNET_RPC_URL is not set"
  exit 1
fi

if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "❌ ERROR: ETHERSCAN_API_KEY is not set"
  exit 1
fi

CHAIN_ID=$("$CAST" chain-id --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || echo "unknown")
echo "=== Network Check ==="
echo "RPC URL: $MAINNET_RPC_URL"
echo "Chain ID: $CHAIN_ID"
if [[ "$CHAIN_ID" != "0x1" ]] && [[ "$CHAIN_ID" != "1" ]]; then
  echo "⚠️  WARNING: Expected Mainnet chain ID (1), got: $CHAIN_ID"
  echo "   Press Ctrl+C to cancel, or wait 10 seconds to continue..."
  sleep 10
fi
echo ""

DEPLOYMENT_FILES=()
if [[ -n "${DEPLOYMENT_FILE:-}" ]]; then
  DEPLOYMENT_FILES=("$DEPLOYMENT_FILE")
else
  shopt -s nullglob
  DEPLOYMENT_FILES=(deployments/mainnet/*-zap-*.json)
  shopt -u nullglob
fi

if [[ ${#DEPLOYMENT_FILES[@]} -eq 0 ]]; then
  echo "❌ No deployment files found."
  exit 1
fi

verify_contract() {
  local address=$1
  local contract_path=$2
  local constructor_args=$3
  local label=$4

  echo "Verifying $label at $address..."

  local code
  code=$("$CAST" code "$address" --rpc-url "$MAINNET_RPC_URL" 2>/dev/null | head -1 || echo "0x")
  if [[ "$code" == "0x" ]]; then
    echo "  ❌ No contract code at address"
    return 1
  fi

  local max_retries=3
  local retry=0

  while [[ $retry -lt $max_retries ]]; do
    local verify_output
    verify_output=$("$FORGE" verify-contract \
      "$address" \
      "$contract_path" \
      --verifier etherscan \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --compiler-version 0.8.30 \
      --chain mainnet \
      --constructor-args "$constructor_args" \
      --watch 2>&1 || true)

    if echo "$verify_output" | grep -q "Contract successfully verified"; then
      echo "  ✅ Verified successfully"
      return 0
    elif echo "$verify_output" | grep -qi "already verified"; then
      echo "  ✅ Already verified"
      return 0
    else
      retry=$((retry + 1))
      if [[ $retry -lt $max_retries ]]; then
        echo "  ⏳ Retrying verification ($retry/$max_retries)..."
        sleep 5
      else
        echo "  ❌ Verification failed"
        echo "  Error output:"
        echo "$verify_output" | grep -E "(Error|error|Failed|failed)" | head -5
      fi
    fi
  done

  return 1
}

total=0
success=0
failed=0

for file in "${DEPLOYMENT_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "⚠️  Deployment file not found: $file"
    continue
  fi

  echo "=== Verifying File ==="
  echo "File: $file"
  echo ""

  contract=$(jq -r '.contract // empty' "$file" 2>/dev/null || echo "")
  impl_address=$(jq -r '.implementation // empty' "$file" 2>/dev/null || echo "")
  proxy_address=$(jq -r '.proxy // empty' "$file" 2>/dev/null || echo "")
  init_data=$(jq -r '.initializerData // empty' "$file" 2>/dev/null || echo "")

  if [[ -z "$contract" ]] || [[ -z "$impl_address" ]] || [[ -z "$proxy_address" ]] || [[ -z "$init_data" ]]; then
    echo "❌ Missing required fields in $file"
    failed=$((failed + 1))
    continue
  fi

  case "$contract" in
    GenesisETHZap_v4)
      impl_path="src/zap/upgradeable/GenesisETHZap_v4.sol:GenesisETHZap_v4"
      impl_ctor_args=$("$CAST" abi-encode "constructor(address)" "$(jq -r '.constructorArgs.genesis' "$file")")
      ;;
    GenesisUSDCZap_v4)
      impl_path="src/zap/upgradeable/GenesisUSDCZap_v4.sol:GenesisUSDCZap_v4"
      impl_ctor_args=$("$CAST" abi-encode "constructor(address)" "$(jq -r '.constructorArgs.genesis' "$file")")
      ;;
    MinterETHZap_v3)
      impl_path="src/zap/upgradeable/MinterETHZap_v3.sol:MinterETHZap_v3"
      impl_ctor_args=$("$CAST" abi-encode "constructor(address,address)" \
        "$(jq -r '.constructorArgs.minter' "$file")" \
        "$(jq -r '.constructorArgs.referral' "$file")")
      ;;
    MinterUSDCZap_v3)
      impl_path="src/zap/upgradeable/MinterUSDCZap_v3.sol:MinterUSDCZap_v3"
      impl_ctor_args=$("$CAST" abi-encode "constructor(address)" "$(jq -r '.constructorArgs.minter' "$file")")
      ;;
    *)
      echo "❌ Unsupported contract type: $contract"
      failed=$((failed + 1))
      continue
      ;;
  esac

  proxy_path="lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"
  proxy_ctor_args=$("$CAST" abi-encode "constructor(address,bytes)" "$impl_address" "$init_data")

  total=$((total + 2))

  if verify_contract "$impl_address" "$impl_path" "$impl_ctor_args" "$contract implementation"; then
    success=$((success + 1))
  else
    failed=$((failed + 1))
  fi

  if verify_contract "$proxy_address" "$proxy_path" "$proxy_ctor_args" "$contract proxy"; then
    success=$((success + 1))
  else
    failed=$((failed + 1))
  fi

  echo ""
done

echo "=== Verification Summary ==="
echo "Total: $total"
echo "Successful: $success"
echo "Failed: $failed"
echo ""

if [[ $failed -eq 0 ]]; then
  echo "✅ All contracts verified!"
else
  echo "⚠️  Some contracts failed verification. Check the output above for details."
  exit 1
fi
