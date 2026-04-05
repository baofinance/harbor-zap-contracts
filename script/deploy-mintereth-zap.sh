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

CONFIG_FILE=${ZAP_CONFIG_FILE:-deployments/mainnet/zap-addresses.json}
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

if [[ -z "${MINTER_ETH:-}" ]]; then
  if [[ -z "$MARKET" ]]; then
    echo "❌ ERROR: MARKET is required when MINTER_ETH is not set"
    exit 1
  fi
  MINTER_ETH=$(load_config ".markets[\"$MARKET\"].addresses.minterEth")
fi

FINAL_OWNER=${OWNER:-}
if [[ -z "$FINAL_OWNER" ]]; then
  FINAL_OWNER=$(load_config ".owner")
fi

if [[ -z "${MAINNET_RPC_URL:-}" ]]; then
  echo "❌ ERROR: MAINNET_RPC_URL is not set"
  exit 1
fi

# Sign txs with a Foundry keystore account (see: cast wallet import --help) or a raw private key.
declare -a SIGNER_FLAGS
if [[ -n "${DEPLOYER_ACCOUNT:-}" ]]; then
  SIGNER_FLAGS=(--account "$DEPLOYER_ACCOUNT")
  if [[ -n "${DEPLOYER_ACCOUNT_PASSWORD:-}" ]]; then
    SIGNER_FLAGS+=(--password "$DEPLOYER_ACCOUNT_PASSWORD")
  fi
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

if [[ -z "${MINTER_ETH:-}" ]]; then
  echo "❌ ERROR: MINTER_ETH is not set"
  echo "   Set it via env or in $CONFIG_FILE (markets.$MARKET.addresses.minterEth)"
  exit 1
fi

REFERRAL_ETH=${REFERRAL_ETH:-0x0000000000000000000000000000000000000000}

CHAIN_ID=$("$CAST" chain-id --rpc-url "$MAINNET_RPC_URL" 2>/dev/null || echo "unknown")
echo "=== Network Check ==="
echo "RPC URL: $MAINNET_RPC_URL"
echo "Chain ID: $CHAIN_ID"
if [[ "$CHAIN_ID" != "0x1" ]] && [[ "$CHAIN_ID" != "1" ]]; then
  echo "⚠️  WARNING: Expected Mainnet chain ID (1), got: $CHAIN_ID"
  echo "   Press Ctrl+C to cancel, or wait 10 seconds to continue..."
  sleep 10
fi
if [[ -n "${DEPLOYER_ACCOUNT:-}" ]]; then
  echo "Signer: Foundry keystore account \"$DEPLOYER_ACCOUNT\""
else
  echo "Signer: PRIVATE_KEY"
fi
echo ""

DEPLOYMENT_DATE=$(date -u +%Y-%m-%d)
DEPLOYMENT_TS=$(date -u +%Y%m%dT%H%M%SZ)
DEPLOYMENT_DIR="deployments/mainnet/$DEPLOYMENT_DATE"
mkdir -p "$DEPLOYMENT_DIR"
if [[ -n "$MARKET" ]]; then
  DEPLOYMENT_FILE="$DEPLOYMENT_DIR/minter-eth-zap-v3-${MARKET}-${DEPLOYMENT_TS}.json"
else
  DEPLOYMENT_FILE="$DEPLOYMENT_DIR/minter-eth-zap-v3-${DEPLOYMENT_TS}.json"
fi

deploy_contract() {
  local contract_path=$1
  shift
  local -a constructor_args=("$@")

  local deploy_out
  if [[ "$VERIFY" == "true" ]]; then
    deploy_out=$("$FORGE" create "$contract_path" \
      --rpc-url "$MAINNET_RPC_URL" \
      "${SIGNER_FLAGS[@]}" \
      --broadcast \
      --verify \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --constructor-args "${constructor_args[@]}" 2>&1)
  else
    deploy_out=$("$FORGE" create "$contract_path" \
      --rpc-url "$MAINNET_RPC_URL" \
      "${SIGNER_FLAGS[@]}" \
      --broadcast \
      --constructor-args "${constructor_args[@]}" 2>&1)
  fi

  echo "$deploy_out"
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
  code=$("$CAST" code "$address" --rpc-url "$MAINNET_RPC_URL" 2>/dev/null | head -1 || echo "0x")
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
    --chain mainnet \
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

echo "=== Deploying MinterETHZap_v4 (UUPS) ==="
echo ""

IMPLEMENTATION_PATH="src/zap/upgradeable/MinterETHZap_v4.sol:MinterETHZap_v4"
PROXY_PATH="lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

echo "Deploying implementation..."
impl_out=$(deploy_contract "$IMPLEMENTATION_PATH" "$MINTER_ETH" "$REFERRAL_ETH")
impl_address=$(extract_address "$impl_out")

if [[ -z "$impl_address" ]]; then
  echo "❌ Failed to deploy implementation"
  echo "$impl_out"
  exit 1
fi

echo "✅ Implementation deployed: $impl_address"

if [[ -n "${DEPLOYER_ACCOUNT:-}" ]]; then
  DEPLOYER=$("$CAST" wallet address --account "$DEPLOYER_ACCOUNT")
else
  DEPLOYER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
fi
init_data=$("$CAST" calldata "initialize(address,address,address)" "$DEPLOYER" "$FINAL_OWNER" "$REFERRAL_ETH")
impl_ctor_args=$("$CAST" abi-encode "constructor(address,address)" "$MINTER_ETH" "$REFERRAL_ETH")

echo "Deploying proxy..."
proxy_out=$(deploy_contract "$PROXY_PATH" "$impl_address" "$init_data")
proxy_address=$(extract_address "$proxy_out")

if [[ -z "$proxy_address" ]]; then
  echo "❌ Failed to deploy proxy"
  echo "$proxy_out"
  exit 1
fi

echo "✅ Proxy deployed: $proxy_address"
echo ""

if ! verify_contract "$impl_address" "$IMPLEMENTATION_PATH" "$impl_ctor_args" "MinterETHZap_v4 implementation"; then
  exit 1
fi
proxy_ctor_args=$("$CAST" abi-encode "constructor(address,bytes)" "$impl_address" "$init_data")
if ! verify_contract "$proxy_address" "$PROXY_PATH" "$proxy_ctor_args" "ERC1967Proxy"; then
  exit 1
fi

if [[ -z "$MARKET" ]]; then
  echo "❌ ERROR: MARKET is required to load stability pools when MINTER_ETH is not set"
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
      "$CAST" send "$proxy_address" "setStabilityPoolAllowed(address,bool)" "$pool" "true" \
        --rpc-url "$MAINNET_RPC_URL" \
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
  "chainId": 1,
  "chainName": "Mainnet",
${NOTE_JSON}  "deploymentTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contract": "MinterETHZap_v4",
  "implementation": "$impl_address",
  "proxy": "$proxy_address",
  "constructorArgs": {
    "minter": "$MINTER_ETH",
    "referral": "$REFERRAL_ETH"
  },
  "initializer": {
    "signature": "initialize(address,address,address)",
    "args": {
      "deployerOwner": "$DEPLOYER",
      "pendingOwner": "$FINAL_OWNER",
      "referral": "$REFERRAL_ETH"
    }
  },
  "initializerData": "$init_data",
  "finalOwner": "$FINAL_OWNER"
}
EOF

if [[ "$(echo "$FINAL_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "Transferring ownership to $FINAL_OWNER..."
  "$CAST" send "$proxy_address" "transferOwnership(address)" "$FINAL_OWNER" \
    --rpc-url "$MAINNET_RPC_URL" \
    "${SIGNER_FLAGS[@]}"
fi

echo "📄 Deployment file saved: $DEPLOYMENT_FILE"
echo ""
echo "Proxy address: $proxy_address"
