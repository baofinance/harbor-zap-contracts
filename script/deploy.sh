#!/usr/bin/env bash
set -euo pipefail

# Salted (CREATE3 via BaoFactory) deploy of Harbor zap proxies — canonical address-stable path.
# Wraps script/Deploy_Zaps.s.sol. Requires the deployer to be a BaoFactory operator.
# Signer: Foundry keystore only (`--account` / DEPLOYER_ACCOUNT). PRIVATE_KEY is not accepted.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [[ -f "$ROOT_DIR/script/_load-env.sh" ]]; then
  # shellcheck source=script/_load-env.sh
  source "$ROOT_DIR/script/_load-env.sh"
fi

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}
TIMEOUT="${DEPLOY_TIMEOUT:-900}"
VERIFY_RETRIES="${VERIFY_RETRIES:-12}"
VERIFY_DELAY="${VERIFY_DELAY:-20}"

usage() {
  cat <<'EOF'
Usage:
  script/deploy.sh --network <name> --market <KEY> [zap address env...] [--account <keystore>] [--sender <addr>] [--no-verify]

Required:
  --network <v>   foundry.toml rpc_endpoints key (mainnet|megaeth|local|...)
  --market <KEY>  market namespace for salt + state file (ETH|BTC|GOLD|...)

Zap targets (at least one; also accepted as env vars):
  --genesis-eth <addr> / GENESIS_ETH
  --genesis-usdc <addr> / GENESIS_USDC
  --minter-eth <addr> / MINTER_ETH
  --minter-usdc <addr> / MINTER_USDC

Options:
  --account <name>   Foundry keystore account (default: $DEPLOYER_ACCOUNT or "deployer").
  --sender <addr>    Deployer EOA (default: derived from the keystore).
  --no-verify        Skip Etherscan verification.
  --resume           Pass --resume to forge.
  -h, --help         Show help.

Signer is keystore-only. Import with: cast wallet import <name> --interactive
PRIVATE_KEY is legacy and rejected. Password: interactive prompt, or set
DEPLOYER_ACCOUNT_PASSWORD for non-interactive runs on a trusted host.
EOF
}

NETWORK=""
MARKET="${MARKET:-}"
ACCOUNT="${DEPLOYER_ACCOUNT:-deployer}"
SENDER=""
VERIFY=true
RESUME=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --market) MARKET=${2:-}; shift 2 ;;
    --genesis-eth) GENESIS_ETH=${2:-}; shift 2 ;;
    --genesis-usdc) GENESIS_USDC=${2:-}; shift 2 ;;
    --minter-eth) MINTER_ETH=${2:-}; shift 2 ;;
    --minter-usdc) MINTER_USDC=${2:-}; shift 2 ;;
    --account) ACCOUNT=${2:-}; shift 2 ;;
    --sender) SENDER=${2:-}; shift 2 ;;
    --no-verify) VERIFY=false; shift ;;
    --resume) RESUME=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f foundry.toml ]] || { echo "❌ Run from the repo root" >&2; exit 1; }
[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }
[[ -n "$MARKET" ]] || { echo "❌ Missing --market" >&2; usage >&2; exit 1; }

if [[ -z "${GENESIS_ETH:-}${GENESIS_USDC:-}${MINTER_ETH:-}${MINTER_USDC:-}" ]]; then
  echo "❌ Set at least one zap target (--genesis-eth / --genesis-usdc / --minter-eth / --minter-usdc)" >&2
  usage >&2
  exit 1
fi

if [[ -n "${PRIVATE_KEY:-}" ]]; then
  echo "❌ PRIVATE_KEY is legacy and not accepted. Use a Foundry keystore:" >&2
  echo "   cast wallet import $ACCOUNT --interactive" >&2
  echo "   yarn deploy --network $NETWORK --market $MARKET --account $ACCOUNT ..." >&2
  exit 1
fi

# Ensure the foundry.toml rpc alias has an underlying URL (without putting it on forge argv).
ensure_rpc_configured() {
  local network=$1
  case "$network" in
    mainnet) [[ -n "${MAINNET_RPC_URL:-}" ]] || {
      echo "❌ MAINNET_RPC_URL required for --network mainnet" >&2
      exit 1
    } ;;
    megaeth) [[ -n "${MEGAETH_RPC_URL:-}" ]] || {
      echo "❌ MEGAETH_RPC_URL required for --network megaeth" >&2
      exit 1
    } ;;
    local) : "${LOCAL_URL:=http://127.0.0.1:8545}"
      export LOCAL_URL
      ;;
    sepolia) [[ -n "${SEPOLIA_RPC_URL:-}" ]] || {
      echo "❌ SEPOLIA_RPC_URL required for --network sepolia" >&2
      exit 1
    } ;;
  esac
}
ensure_rpc_configured "$NETWORK"

# Keystore signer. Prefer interactive password unlock (keeps passphrase out of argv).
# DEPLOYER_ACCOUNT_PASSWORD is optional for non-interactive automation on a trusted host.
SIGNER=(--account "$ACCOUNT")
if [[ -n "${DEPLOYER_ACCOUNT_PASSWORD:-}" ]]; then
  SIGNER+=(--password "$DEPLOYER_ACCOUNT_PASSWORD")
fi
if [[ -z "$SENDER" ]]; then
  SENDER=$("$CAST" wallet address "${SIGNER[@]}")
fi

if [[ "$VERIFY" == true ]] && [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "⚠️  ETHERSCAN_API_KEY not set; continuing without --verify."
  VERIFY=false
fi

# Use foundry.toml rpc alias so provider URLs/credentials are not expanded into argv.
RPC_ALIAS=$NETWORK

# Fail closed when the RPC is not the network the operator named (skip for local / unknown aliases).
expected_chain_id() {
  case "$1" in
    mainnet) echo 1 ;;
    megaeth) echo 4326 ;;
    *) echo "" ;;
  esac
}
EXPECTED_CHAIN_ID=$(expected_chain_id "$NETWORK")
if [[ -n "$EXPECTED_CHAIN_ID" ]]; then
  CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_ALIAS" 2>/dev/null || echo "")
  if [[ -z "$CHAIN_ID" ]]; then
    echo "❌ Cannot determine chain ID from RPC alias: $RPC_ALIAS" >&2
    exit 1
  fi
  if [[ "$CHAIN_ID" =~ ^0[xX] ]]; then
    CHAIN_ID=$((16#${CHAIN_ID:2}))
  fi
  if [[ "$CHAIN_ID" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "❌ Chain ID mismatch for --network $NETWORK: expected $EXPECTED_CHAIN_ID, RPC reports $CHAIN_ID" >&2
    exit 1
  fi
fi

export MARKET
[[ -n "${GENESIS_ETH:-}" ]] && export GENESIS_ETH
[[ -n "${GENESIS_USDC:-}" ]] && export GENESIS_USDC
[[ -n "${MINTER_ETH:-}" ]] && export MINTER_ETH
[[ -n "${MINTER_USDC:-}" ]] && export MINTER_USDC

echo "=== Harbor Zap deploy (salted / CREATE3) — $NETWORK / $MARKET ==="
echo "  account: $ACCOUNT   sender: $SENDER   verify: $VERIFY"

cmd=("$FORGE" script script/Deploy_Zaps.s.sol:Deploy_Zaps
  --rpc-url "$RPC_ALIAS" --broadcast --slow --timeout "$TIMEOUT" --sender "$SENDER" "${SIGNER[@]}")
[[ "$NETWORK" == "megaeth" ]] && cmd+=(--skip-simulation)
[[ "$VERIFY" == true ]] && cmd+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
[[ "$RESUME" == true ]] && cmd+=(--resume)
"${cmd[@]}"
