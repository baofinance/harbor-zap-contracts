#!/bin/bash

# ============================================================
# DEPLOYMENT COMMANDS FOR GENESIS ZAP CONTRACTS
# ============================================================
# 
# Environment variables required:
# - RPC_URL
# - ETHERSCAN_API_KEY
# - OWNER (address to transfer ownership to after deployment)
# - PRIVATE_KEY
#
# Genesis contract addresses:
# - wstETH Genesis: 0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0
# - fxSAVE Genesis 1: 0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe
# - fxSAVE Genesis 2: 0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073
# ============================================================

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
DEPLOYMENTS_DIR="$PROJECT_ROOT/deployments"
DEPLOYMENT_FILE="$DEPLOYMENTS_DIR/genesis-zaps-$(date +%Y%m%d-%H%M%S).json"

# Create deployments directory if it doesn't exist
mkdir -p "$DEPLOYMENTS_DIR"

# Check required environment variables
if [ -z "$RPC_URL" ] || [ -z "$ETHERSCAN_API_KEY" ] || [ -z "$OWNER" ] || [ -z "$PRIVATE_KEY" ]; then
    echo "Error: Missing required environment variables"
    echo "Required: RPC_URL, ETHERSCAN_API_KEY, OWNER, PRIVATE_KEY"
    exit 1
fi

# Initialize deployment file
cat > "$DEPLOYMENT_FILE" <<EOF
{
  "network": "$(echo $RPC_URL | grep -oE '(mainnet|sepolia|localhost|anvil)' || echo 'unknown')",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployer": "$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo 'unknown')",
  "owner": "$OWNER",
  "genesisContracts": {
    "wstETH": "0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0",
    "fxSAVE_1": "0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe",
    "fxSAVE_2": "0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073"
  },
  "zapContracts": {
    "GenesisETHZap_v3": "",
    "GenesisUSDCZap_v2_fxSAVE_1": "",
    "GenesisUSDCZap_v2_fxSAVE_2": ""
  }
}
EOF

echo "Deployment file created: $DEPLOYMENT_FILE"
echo ""

# 1. Deploy GenesisETHZap_v3 (for wstETH Genesis)
# Constructor: (address genesis_, address referral_)
# Referral: 0x0000000000000000000000000000000000000000 uses default (0x3dFc49e5112005179Da613BdE5973229082dAc35)
echo "Deploying GenesisETHZap_v3..."
ZAP_ETH_ADDRESS=$(forge create src/zap/GenesisETHZap_v3.sol:GenesisETHZapV3 \
  --constructor-args 0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0 0x0000000000000000000000000000000000000000 \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --etherscan-api-key ${ETHERSCAN_API_KEY} \
  --verify \
  | grep "Deployed to:" | awk '{print $3}')

if [ -z "$ZAP_ETH_ADDRESS" ]; then
    echo "Error: Failed to deploy GenesisETHZap_v3"
    exit 1
fi

echo "GenesisETHZap_v3 deployed to: $ZAP_ETH_ADDRESS"
echo "Transferring ownership to: $OWNER"

# Transfer ownership to OWNER
cast send $ZAP_ETH_ADDRESS \
  "transferOwnership(address)" $OWNER \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --gas-limit 100000

echo "Ownership transferred for GenesisETHZap_v3"

# Update deployment file
cat > "$DEPLOYMENT_FILE" <<EOF
{
  "network": "$(echo $RPC_URL | grep -oE '(mainnet|sepolia|localhost|anvil)' || echo 'unknown')",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployer": "$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo 'unknown')",
  "owner": "$OWNER",
  "genesisContracts": {
    "wstETH": "0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0",
    "fxSAVE_1": "0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe",
    "fxSAVE_2": "0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073"
  },
  "zapContracts": {
    "GenesisETHZap_v3": "$ZAP_ETH_ADDRESS",
    "GenesisUSDCZap_v2_fxSAVE_1": "",
    "GenesisUSDCZap_v2_fxSAVE_2": ""
  }
}
EOF
echo ""

# 2. Deploy GenesisUSDCZap_v2 (for first fxSAVE Genesis)
# Constructor: (address genesis_)
echo "Deploying GenesisUSDCZap_v2 (fxSAVE #1)..."
ZAP_USDC_1_ADDRESS=$(forge create src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
  --constructor-args 0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --etherscan-api-key ${ETHERSCAN_API_KEY} \
  --verify \
  | grep "Deployed to:" | awk '{print $3}')

if [ -z "$ZAP_USDC_1_ADDRESS" ]; then
    echo "Error: Failed to deploy GenesisUSDCZap_v2 (fxSAVE #1)"
    exit 1
fi

echo "GenesisUSDCZap_v2 (fxSAVE #1) deployed to: $ZAP_USDC_1_ADDRESS"
echo "Transferring ownership to: $OWNER"

# Transfer ownership to OWNER
cast send $ZAP_USDC_1_ADDRESS \
  "transferOwnership(address)" $OWNER \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --gas-limit 100000

echo "Ownership transferred for GenesisUSDCZap_v2 (fxSAVE #1)"

# Update deployment file
cat > "$DEPLOYMENT_FILE" <<EOF
{
  "network": "$(echo $RPC_URL | grep -oE '(mainnet|sepolia|localhost|anvil)' || echo 'unknown')",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployer": "$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo 'unknown')",
  "owner": "$OWNER",
  "genesisContracts": {
    "wstETH": "0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0",
    "fxSAVE_1": "0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe",
    "fxSAVE_2": "0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073"
  },
  "zapContracts": {
    "GenesisETHZap_v3": "$ZAP_ETH_ADDRESS",
    "GenesisUSDCZap_v2_fxSAVE_1": "$ZAP_USDC_1_ADDRESS",
    "GenesisUSDCZap_v2_fxSAVE_2": ""
  }
}
EOF
echo ""

# 3. Deploy GenesisUSDCZap_v2 (for second fxSAVE Genesis)
# Constructor: (address genesis_)
echo "Deploying GenesisUSDCZap_v2 (fxSAVE #2)..."
ZAP_USDC_2_ADDRESS=$(forge create src/zap/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
  --constructor-args 0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073 \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --etherscan-api-key ${ETHERSCAN_API_KEY} \
  --verify \
  | grep "Deployed to:" | awk '{print $3}')

if [ -z "$ZAP_USDC_2_ADDRESS" ]; then
    echo "Error: Failed to deploy GenesisUSDCZap_v2 (fxSAVE #2)"
    exit 1
fi

echo "GenesisUSDCZap_v2 (fxSAVE #2) deployed to: $ZAP_USDC_2_ADDRESS"
echo "Transferring ownership to: $OWNER"

# Transfer ownership to OWNER
cast send $ZAP_USDC_2_ADDRESS \
  "transferOwnership(address)" $OWNER \
  --rpc-url ${RPC_URL} \
  --private-key ${PRIVATE_KEY} \
  --gas-limit 100000

echo "Ownership transferred for GenesisUSDCZap_v2 (fxSAVE #2)"
echo ""

# Final deployment file update
cat > "$DEPLOYMENT_FILE" <<EOF
{
  "network": "$(echo $RPC_URL | grep -oE '(mainnet|sepolia|localhost|anvil)' || echo 'unknown')",
  "deployedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployer": "$(cast wallet address $PRIVATE_KEY 2>/dev/null || echo 'unknown')",
  "owner": "$OWNER",
  "genesisContracts": {
    "wstETH": "0x9Ae0B57CeADa0056Dbe21edcd638476FcBA3ccc0",
    "fxSAVE_1": "0x288c61C3B3684FF21ADf38d878c81457B19BD2Fe",
    "fxSAVE_2": "0x5f4398e1d3e33F93e3D7ee710D797E2a154cB073"
  },
  "zapContracts": {
    "GenesisETHZap_v3": "$ZAP_ETH_ADDRESS",
    "GenesisUSDCZap_v2_fxSAVE_1": "$ZAP_USDC_1_ADDRESS",
    "GenesisUSDCZap_v2_fxSAVE_2": "$ZAP_USDC_2_ADDRESS"
  }
}
EOF

echo "=========================================="
echo "Deployment Summary:"
echo "=========================================="
echo "GenesisETHZap_v3:      $ZAP_ETH_ADDRESS"
echo "GenesisUSDCZap_v2 (#1): $ZAP_USDC_1_ADDRESS"
echo "GenesisUSDCZap_v2 (#2): $ZAP_USDC_2_ADDRESS"
echo "Owner:                  $OWNER"
echo "=========================================="
echo ""
echo "Deployment addresses saved to: $DEPLOYMENT_FILE"
