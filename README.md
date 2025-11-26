# Harbor Zap Contracts

One-click zapper contracts for depositing collateral into Harbor Genesis and Minter contracts.

## Overview

This repository contains zap contracts that enable users to deposit collateral in a single transaction:

- **ETH/wstETH Zaps**: Convert ETH or stETH to wstETH and deposit into Genesis/Minter contracts
- **USDC/fxSAVE Zaps**: Convert USDC or fxUSD to fxSAVE and deposit into Genesis/Minter contracts

## Contracts

### ETH/wstETH Zap Contracts

- `GenesisETHZap_v2`: Zap ETH or stETH into Genesis contracts
- `MinterETHZap_v2`: Zap ETH or stETH to mint pegged or leveraged tokens

### USDC/fxSAVE Zap Contracts

- `GenesisUSDCZap_v2`: Zap USDC or fxUSD into Genesis contracts
- `MinterUSDCZap_v2`: Zap USDC or fxUSD to mint pegged or leveraged tokens

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Access to an Ethereum RPC endpoint (for mainnet deployments)
- Private key with sufficient ETH for gas fees

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd harbor-zap-contracts
```

2. Install dependencies:
```bash
forge install
```

3. Build the contracts:
```bash
forge build
```

## Testing

Run the test suite:
```bash
forge test
```

For fork tests, set the `MAINNET_RPC_URL` environment variable:
```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
forge test
```

## Deployment

### Quick Deployment

Deploy ETH/wstETH zap contracts (uses default Genesis/Minter addresses):
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
bash script/deploy-eth-zaps.sh
```

To use different Genesis/Minter addresses for ETH/wstETH:
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export GENESIS_ETH="0xYOUR_GENESIS_ETH_ADDRESS"    # Optional: override default
export MINTER_ETH="0xYOUR_MINTER_ETH_ADDRESS"      # Optional: override default
export REFERRAL_ETH="0xYOUR_REFERRAL_ADDRESS"      # Optional: override default
bash script/deploy-eth-zaps.sh
```

Deploy USDC/fxSAVE zap contracts (requires Genesis/Minter addresses):
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export GENESIS_USDC="0xYOUR_GENESIS_USDC_ADDRESS"  # Required
export MINTER_USDC="0xYOUR_MINTER_USDC_ADDRESS"    # Required
bash script/deploy-usdc-zaps.sh
```

### Deployment Scripts

#### ETH/wstETH Deployment (`script/deploy-eth-zaps.sh`)

Deploys:
- `GenesisETHZap_v2`
- `MinterETHZap_v2`

**Default Configuration:**
- Genesis: `0x59C2776E88fF80841c88138a2CD0f375F544EeaE`
- Minter: `0x6d64EC8B95Eeab780745d3bDF5BB06D08e38cC29`
- Referral: `0x3dFc49e5112005179Da613BdE5973229082dAc35` (Harbor's Lido referral)

**Environment Variables:**
- `RPC_URL`: Ethereum RPC endpoint (default: `http://127.0.0.1:8545`)
- `PRIVATE_KEY`: Deployer private key (required)
- `GENESIS_ETH`: Genesis contract address (optional, has default: `0x59C2776E88fF80841c88138a2CD0f375F544EeaE`)
- `MINTER_ETH`: Minter contract address (optional, has default: `0x6d64EC8B95Eeab780745d3bDF5BB06D08e38cC29`)
- `REFERRAL_ETH`: Lido referral address (optional, has default: `0x3dFc49e5112005179Da613BdE5973229082dAc35`)

**Usage (with defaults):**
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
bash script/deploy-eth-zaps.sh
```

**Usage (with custom addresses):**
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export GENESIS_ETH="0xYOUR_CUSTOM_GENESIS_ADDRESS"
export MINTER_ETH="0xYOUR_CUSTOM_MINTER_ADDRESS"
export REFERRAL_ETH="0xYOUR_CUSTOM_REFERRAL_ADDRESS"  # Optional
bash script/deploy-eth-zaps.sh
```

#### USDC/fxSAVE Deployment (`script/deploy-usdc-zaps.sh`)

Deploys:
- `GenesisUSDCZap_v2`
- `MinterUSDCZap_v2`

**Required Environment Variables:**
- `RPC_URL`: Ethereum RPC endpoint
- `PRIVATE_KEY`: Deployer private key
- `GENESIS_USDC`: Genesis contract address (must accept fxSAVE as collateral)
- `MINTER_USDC`: Minter contract address (must accept fxSAVE as collateral)

**Usage:**
```bash
export RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
export GENESIS_USDC="0xYOUR_GENESIS_USDC_ADDRESS"
export MINTER_USDC="0xYOUR_MINTER_USDC_ADDRESS"
bash script/deploy-usdc-zaps.sh
```

### Manual Deployment

You can also deploy contracts manually using `forge create`:

**GenesisETHZap_v2:**
```bash
forge create src/minter/GenesisETHZap_v2.sol:GenesisETHZapV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args <GENESIS_ADDRESS> <REFERRAL_ADDRESS>
```

**MinterETHZap_v2:**
```bash
forge create src/minter/MinterETHZap_v2.sol:MinterETHZapV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args <MINTER_ADDRESS> <REFERRAL_ADDRESS>
```

**GenesisUSDCZap_v2:**
```bash
forge create src/minter/GenesisUSDCZap_v2.sol:GenesisUSDCZapV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args <GENESIS_ADDRESS>
```

**MinterUSDCZap_v2:**
```bash
forge create src/minter/MinterUSDCZap_v2.sol:MinterUSDCZapV2 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --constructor-args <MINTER_ADDRESS>
```

### Deployment to Anvil Fork (Local Testing)

For local testing with an Anvil fork:

1. Start Anvil with a mainnet fork:
```bash
anvil --fork-url https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY --host 0.0.0.0 --port 8546
```

2. Deploy to the fork:
```bash
export RPC_URL="http://127.0.0.1:8546"
export PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"  # Anvil default
bash script/deploy-eth-zaps.sh
```

## Post-Deployment

After deployment, you should:

1. **Transfer Ownership**: Transfer ownership of the zap contracts to your desired owner address:
```bash
cast send <ZAP_ADDRESS> "transferOwnership(address)" <NEW_OWNER> \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

2. **Verify Contracts** (optional): Verify contracts on Etherscan:
```bash
forge verify-contract <CONTRACT_ADDRESS> \
  src/minter/<ContractName>.sol:<ContractName> \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id 1
```

3. **Update Referral** (ETH zaps only, optional): Update Lido referral address if needed:
```bash
cast send <ZAP_ADDRESS> "setReferral(address)" <NEW_REFERRAL> \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

## Contract Addresses

### Mainnet (when deployed)

ETH/wstETH Zaps:
- GenesisETHZap_v2: TBD
- MinterETHZap_v2: TBD

USDC/fxSAVE Zaps:
- GenesisUSDCZap_v2: TBD
- MinterUSDCZap_v2: TBD

## Security Considerations

- **Private Keys**: Never commit private keys to version control
- **Ownership**: Transfer ownership to a multisig or secure address after deployment
- **Referral**: The referral address receives rewards from Lido for ETH deposits
- **Access Control**: Zap contracts have owner-only functions for rescue operations

## Development

### Project Structure

```
harbor-zap-contracts/
├── src/
│   ├── interfaces/      # Interface definitions
│   ├── minter/          # Zap contract implementations
│   └── util/            # Utility contracts (ReentrancyGuard, etc.)
├── test/                # Test files
├── script/              # Deployment scripts
└── foundry.toml         # Foundry configuration
```

### Key Dependencies

- OpenZeppelin Contracts (upgradeable)
- Bao Base Contracts
- Forge Standard Library

## License

[Add your license here]

## Support

For issues or questions, please open an issue on GitHub.

