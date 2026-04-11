#!/usr/bin/env bash
# Sourced by per-zap deploy scripts (Genesis/Minter UUPS). Sets config path and RPC from network.
# Env:
#   ZAP_NETWORK     mainnet | megaeth (default: mainnet)
#   ZAP_CONFIG_FILE optional override path to zap-addresses.json (absolute or repo-relative)
#   ZAP_RPC_URL     optional; overrides network-specific RPC below
#   MAINNET_RPC_URL required when ZAP_NETWORK=mainnet (unless ZAP_RPC_URL set)
#   MEGAETH_RPC_URL required when ZAP_NETWORK=megaeth (unless ZAP_RPC_URL set)
#
# Sets (export where needed by child tools):
#   CONFIG_FILE, RPC_URL, DEPLOYMENT_ROOT, EXPECTED_CHAIN_ID, VERIFY_CHAIN, DEPLOYMENT_CHAIN_NAME

: "${ROOT_DIR:?ROOT_DIR must be set before sourcing _zap-deploy-env.sh}"

ZAP_NETWORK=${ZAP_NETWORK:-mainnet}
case "$ZAP_NETWORK" in
  mainnet | megaeth) ;;
  *)
    echo "❌ ZAP_NETWORK must be mainnet or megaeth (got: $ZAP_NETWORK)" >&2
    exit 1
    ;;
esac

if [[ -n "${ZAP_CONFIG_FILE:-}" ]]; then
  CONFIG_FILE=$ZAP_CONFIG_FILE
else
  CONFIG_FILE="$ROOT_DIR/deployments/${ZAP_NETWORK}/zap-addresses.json"
fi
if [[ "$CONFIG_FILE" != /* ]]; then
  CONFIG_FILE="$ROOT_DIR/$CONFIG_FILE"
fi

RPC_URL=${ZAP_RPC_URL:-}
if [[ -z "$RPC_URL" ]]; then
  if [[ "$ZAP_NETWORK" == "megaeth" ]]; then
    RPC_URL=${MEGAETH_RPC_URL:-}
  else
    RPC_URL=${MAINNET_RPC_URL:-}
  fi
fi
if [[ -z "$RPC_URL" ]]; then
  echo "❌ RPC URL not set: use ZAP_RPC_URL, or MEGAETH_RPC_URL for megaeth, or MAINNET_RPC_URL for mainnet" >&2
  exit 1
fi

DEPLOYMENT_ROOT="$ROOT_DIR/deployments/${ZAP_NETWORK}"

if [[ "$ZAP_NETWORK" == "megaeth" ]]; then
  EXPECTED_CHAIN_ID=${EXPECTED_CHAIN_ID:-4326}
  VERIFY_CHAIN=${VERIFY_CHAIN:-4326}
else
  EXPECTED_CHAIN_ID=${EXPECTED_CHAIN_ID:-1}
  VERIFY_CHAIN=${VERIFY_CHAIN:-mainnet}
fi

export RPC_URL

DEPLOYMENT_CHAIN_NAME=
if [[ -f "$CONFIG_FILE" ]] && command -v jq >/dev/null 2>&1; then
  DEPLOYMENT_CHAIN_NAME=$(jq -r '.chainName // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi
if [[ -z "$DEPLOYMENT_CHAIN_NAME" ]]; then
  if [[ "$ZAP_NETWORK" == "megaeth" ]]; then
    DEPLOYMENT_CHAIN_NAME="MegaETH"
  else
    DEPLOYMENT_CHAIN_NAME="Mainnet"
  fi
fi
