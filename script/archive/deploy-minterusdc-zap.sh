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

# shellcheck source=script/_zap-deploy-env.sh
source "$ROOT_DIR/script/_zap-deploy-env.sh"
MARKET=${MARKET:-}

load_config() {
  local jq_path=$1
  if [[ -f "$CONFIG_FILE" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "❌ ERROR: jq is required to read $CONFIG_FILE"
      exit 1
    fi
    jq -r "$jq_path // empty" "$CONFIG_FILE"
  fi
}

load_list() {
  local jq_path=$1
  if [[ -f "$CONFIG_FILE" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "❌ ERROR: jq is required to read $CONFIG_FILE"
      exit 1
    fi
    jq -r "$jq_path" "$CONFIG_FILE" 2>/dev/null || true
  fi
}

if [[ -z "${MINTER_USDC:-}" ]]; then
  if [[ -z "$MARKET" ]]; then
    echo "❌ ERROR: MARKET is required when MINTER_USDC is not set"
    exit 1
  fi
  MINTER_USDC=$(load_config ".markets[\"$MARKET\"].addresses.minterUsdc")
fi

FINAL_OWNER=${OWNER:-}
if [[ -z "$FINAL_OWNER" ]]; then
  FINAL_OWNER=$(load_config ".owner")
fi

# Sign txs with a Foundry keystore account (see: cast wallet import --help) or a raw private key.
# Interactive forge inside command substitution ($(...)) can echo the keystore password; we prompt once
# with read -s and pass --password so forge/cast are non-interactive. (Password may be visible in `ps` while
# processes run—use a dedicated deploy machine or inject via 1Password CLI, etc.)
declare -a SIGNER_FLAGS
if [[ -n "${DEPLOYER_ACCOUNT:-}" ]]; then
  if [[ -z "${DEPLOYER_ACCOUNT_PASSWORD:-}" ]]; then
    read -r -s -p "Enter keystore password for \"$DEPLOYER_ACCOUNT\" (input hidden): " DEPLOYER_ACCOUNT_PASSWORD
    echo ""
    export DEPLOYER_ACCOUNT_PASSWORD
  fi
  SIGNER_FLAGS=(--account "$DEPLOYER_ACCOUNT" --password "$DEPLOYER_ACCOUNT_PASSWORD")
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
  SIGNER_FLAGS=(--private-key "$PRIVATE_KEY")
else
  echo "❌ ERROR: Set DEPLOYER_ACCOUNT (keystore name, e.g. deployer) or PRIVATE_KEY"
  exit 1
fi

VERIFY=${VERIFY:-true}
VERIFY_REQUIRED=${VERIFY_REQUIRED:-true}
if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  if [[ "$VERIFY_REQUIRED" == "true" ]]; then
    echo "❌ ERROR: ETHERSCAN_API_KEY is not set (verification required)"
    exit 1
  fi
  echo "⚠️  WARNING: ETHERSCAN_API_KEY is not set. Verification will be skipped."
  VERIFY=false
fi

if [[ -z "$FINAL_OWNER" ]]; then
  echo "❌ ERROR: OWNER is not set"
  exit 1
fi

if [[ -z "${MINTER_USDC:-}" ]]; then
  echo "❌ ERROR: MINTER_USDC is not set"
  echo "   Set it via env or in $CONFIG_FILE (markets.$MARKET.addresses.minterUsdc)"
  exit 1
fi

CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL" 2>/dev/null || echo "unknown")
echo "=== Network Check ==="
echo "ZAP_NETWORK: ${ZAP_NETWORK:-mainnet}"
echo "Config: $CONFIG_FILE"
echo "RPC URL: $RPC_URL"
echo "Chain ID: $CHAIN_ID"
if [[ "$CHAIN_ID" != "unknown" ]]; then
  _cid=$CHAIN_ID
  if [[ "$_cid" =~ ^0[xX] ]]; then
    _cid=$((16#${_cid:2}))
  fi
  if [[ "$_cid" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "⚠️  WARNING: Expected chain ID $EXPECTED_CHAIN_ID, RPC reports: $CHAIN_ID"
    echo "   Press Ctrl+C to cancel, or wait 10 seconds to continue..."
    sleep 10
  fi
fi
if [[ -n "${DEPLOYER_ACCOUNT:-}" ]]; then
  echo "Signer: Foundry keystore account \"$DEPLOYER_ACCOUNT\""
else
  echo "Signer: PRIVATE_KEY"
fi
echo ""

DEPLOYMENT_DATE=$(date -u +%Y-%m-%d)
DEPLOYMENT_TS=$(date -u +%Y%m%dT%H%M%SZ)
DEPLOYMENT_DIR="$DEPLOYMENT_ROOT/$DEPLOYMENT_DATE"
mkdir -p "$DEPLOYMENT_DIR"
if [[ -n "$MARKET" ]]; then
  DEPLOYMENT_FILE="$DEPLOYMENT_DIR/minter-usdc-zap-v3-${MARKET}-${DEPLOYMENT_TS}.json"
else
  DEPLOYMENT_FILE="$DEPLOYMENT_DIR/minter-usdc-zap-v3-${DEPLOYMENT_TS}.json"
fi

# Log file must be first arg; streams forge output to terminal via tee (avoids $() breaking keystore TTY).
deploy_contract() {
  local log_file=$1
  shift
  local contract_path=$1
  shift
  local -a constructor_args=("$@")

  if [[ "$VERIFY" == "true" ]]; then
    "$FORGE" create "$contract_path" \
      --rpc-url "$RPC_URL" \
      "${SIGNER_FLAGS[@]}" \
      --broadcast \
      --verify \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --constructor-args "${constructor_args[@]}" 2>&1 | tee "$log_file"
  else
    "$FORGE" create "$contract_path" \
      --rpc-url "$RPC_URL" \
      "${SIGNER_FLAGS[@]}" \
      --broadcast \
      --constructor-args "${constructor_args[@]}" 2>&1 | tee "$log_file"
  fi
  return "${PIPESTATUS[0]}"
}

extract_address() {
  echo "$1" | grep -Eo "Deployed to: 0x[0-9a-fA-F]{40}" | awk '{print $3}'
}

verify_contract() {
  local address=$1
  local contract_path=$2
  local constructor_args=$3
  local label=$4

  if [[ "${VERIFY:-true}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
    echo "⚠️  WARNING: ETHERSCAN_API_KEY is not set. Skipping verification."
    return 0
  fi

  local code
  code=$("$CAST" code "$address" --rpc-url "$RPC_URL" 2>/dev/null | head -1 || echo "0x")
  if [[ "$code" == "0x" ]]; then
    echo "❌ No contract code at $address for $label"
    return 1
  fi

  local verify_output
  verify_output=$("$FORGE" verify-contract \
    "$address" \
    "$contract_path" \
    --verifier etherscan \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --compiler-version 0.8.30 \
    --chain "$VERIFY_CHAIN" \
    --constructor-args "$constructor_args" \
    --watch 2>&1 || true)

  if echo "$verify_output" | grep -q "Contract successfully verified"; then
    echo "✅ Verified $label"
    return 0
  elif echo "$verify_output" | grep -qi "already verified"; then
    echo "✅ $label already verified"
    return 0
  else
    echo "⚠️  Verification failed for $label"
    echo "$verify_output" | grep -E "(Error|error|Failed|failed)" | head -5
    return 1
  fi
}

echo "=== Deploying MinterUSDCZap_v4 (UUPS) ==="
echo ""

IMPLEMENTATION_PATH="src/zap/upgradeable/MinterUSDCZap_v4.sol:MinterUSDCZap_v4"
PROXY_PATH="lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

IMPL_LOG=$(mktemp "${TMPDIR:-/tmp}/zap-impl.XXXXXX")
PROXY_LOG=$(mktemp "${TMPDIR:-/tmp}/zap-proxy.XXXXXX")
trap 'rm -f "$IMPL_LOG" "$PROXY_LOG"' EXIT

echo "Deploying implementation..."
if ! deploy_contract "$IMPL_LOG" "$IMPLEMENTATION_PATH" "$MINTER_USDC"; then
  echo "❌ Failed to deploy implementation"
  cat "$IMPL_LOG"
  exit 1
fi
impl_address=$(extract_address "$(cat "$IMPL_LOG")")

if [[ -z "$impl_address" ]]; then
  echo "❌ Failed to deploy implementation (no address in log)"
  cat "$IMPL_LOG"
  exit 1
fi

echo "✅ Implementation deployed: $impl_address"

DEPLOYER=$("$CAST" wallet address "${SIGNER_FLAGS[@]}")
init_data=$("$CAST" calldata "initialize(address,address)" "$DEPLOYER" "$FINAL_OWNER")
impl_ctor_args=$("$CAST" abi-encode "constructor(address)" "$MINTER_USDC")

echo "Deploying proxy..."
if ! deploy_contract "$PROXY_LOG" "$PROXY_PATH" "$impl_address" "$init_data"; then
  echo "❌ Failed to deploy proxy"
  cat "$PROXY_LOG"
  exit 1
fi
proxy_address=$(extract_address "$(cat "$PROXY_LOG")")

if [[ -z "$proxy_address" ]]; then
  echo "❌ Failed to deploy proxy (no address in log)"
  cat "$PROXY_LOG"
  exit 1
fi

echo "✅ Proxy deployed: $proxy_address"
echo ""

if ! verify_contract "$impl_address" "$IMPLEMENTATION_PATH" "$impl_ctor_args" "MinterUSDCZap_v4 implementation"; then
  exit 1
fi
proxy_ctor_args=$("$CAST" abi-encode "constructor(address,bytes)" "$impl_address" "$init_data")
if ! verify_contract "$proxy_address" "$PROXY_PATH" "$proxy_ctor_args" "ERC1967Proxy"; then
  exit 1
fi

if [[ -z "$MARKET" ]]; then
  echo "❌ ERROR: MARKET is required to load stability pools when MINTER_USDC is not set"
  exit 1
fi
# Bash 3.2 (macOS default) has no mapfile
stability_pools=()
while IFS= read -r pool || [[ -n "$pool" ]]; do
  [[ -n "$pool" ]] && stability_pools+=("$pool")
done < <(load_list ".markets[\"$MARKET\"].stabilityPools[]?")
if (( ${#stability_pools[@]} > 0 )); then
  echo "Setting allowed stability pools..."
  for pool in "${stability_pools[@]}"; do
    if [[ -n "$pool" ]]; then
      # Wait for each tx (nonce advances on-chain). CAST_ASYNC=true in .env causes "nonce too low" on the next send.
      CAST_ASYNC=false "$CAST" send "$proxy_address" "setStabilityPoolAllowed(address,bool)" "$pool" "true" \
        --rpc-url "$RPC_URL" \
        --confirmations 1 \
        "${SIGNER_FLAGS[@]}"
    fi
  done
fi

DEPLOY_NOTE=${DEPLOY_NOTE:-}
NOTE_JSON=""
if [[ -n "$DEPLOY_NOTE" ]]; then
  note_escaped=${DEPLOY_NOTE//\\/\\\\}
  note_escaped=${note_escaped//\"/\\\"}
  NOTE_JSON=$(printf '  "note": "%s",\n' "$note_escaped")
fi

cat > "$DEPLOYMENT_FILE" <<EOF
{
  "schemaVersion": 1,
  "chainId": ${EXPECTED_CHAIN_ID},
  "chainName": "${DEPLOYMENT_CHAIN_NAME}",
${NOTE_JSON}  "deploymentTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contract": "MinterUSDCZap_v4",
  "implementation": "$impl_address",
  "proxy": "$proxy_address",
  "constructorArgs": {
    "minter": "$MINTER_USDC"
  },
  "initializer": {
    "signature": "initialize(address,address)",
    "args": {
      "deployerOwner": "$DEPLOYER",
      "pendingOwner": "$FINAL_OWNER"
    }
  },
  "initializerData": "$init_data",
  "finalOwner": "$FINAL_OWNER"
}
EOF

if [[ "$(echo "$FINAL_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Transferring ownership to $FINAL_OWNER..."
  CAST_ASYNC=false "$CAST" send "$proxy_address" "transferOwnership(address)" "$FINAL_OWNER" \
    --rpc-url "$RPC_URL" \
    --confirmations 1 \
    "${SIGNER_FLAGS[@]}"
fi

echo "📄 Deployment file saved: $DEPLOYMENT_FILE"
echo ""
echo "Proxy address: $proxy_address"
