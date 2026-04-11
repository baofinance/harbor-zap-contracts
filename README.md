<p align="center">
  <a href="https://www.harborfinance.io/">
    <img src="https://github.com/baofinance/harbor-app/raw/main/public/logo.svg"
         alt="Harbor Protocol - A Safer Harbor For Leverage, Uncharted Waters For Yield"
         width="480"
         style="max-width:100%; height:auto;">
  </a>
</p>

<p align="center">
  <br>
  <i>A Safer Harbor For Leverage, Uncharted Waters For Yield.</i><br>
</p>

<br>

# Harbor Zap Contracts

One-click zapper contracts for depositing collateral into Harbor Genesis and Minter contracts.

## Overview

This repository contains zap contracts that enable users to deposit collateral in a single transaction:

- **ETH/wstETH Zaps**: Convert ETH or stETH to wstETH and deposit into Genesis/Minter contracts
- **USDC/fxSAVE Zaps**: Convert USDC or fxUSD to fxSAVE and deposit into Genesis/Minter contracts

## Contracts

### ETH/wstETH Zap Contracts

- `GenesisETHZap_v5`: Zap ETH or stETH into Genesis contracts (upgradeable)
- `MinterETHZap_v4`: Zap ETH or stETH to mint pegged or leveraged tokens, or deposit into Stability Pools (upgradeable)

### USDC/fxSAVE Zap Contracts

- `GenesisUSDCZap_v5`: Zap USDC or fxUSD into Genesis contracts (upgradeable)
- `MinterUSDCZap_v4`: Zap USDC or fxUSD to mint pegged or leveraged tokens, or deposit into Stability Pools (upgradeable)

## Operator notes

Current zap set (`GenesisETHZap_v5`, `GenesisUSDCZap_v5`, `MinterETHZap_v4`, `MinterUSDCZap_v4`) is production-ready and safety-first (slippage bounds, balance-delta checks, reentrancy protection, allowlisted stability pools, and mint/share validation). Most gas cost is external protocol interaction, not local control flow.

If you do a future optimization pass, treat it as maintainability work (shared helpers/base for duplicated minter patterns) and run full upgrade safety checks.

For upgrade prep, use `script/dump-zap-storage-layout.sh` plus `extra_output = ["storageLayout"]` in `foundry.toml` to diff layouts before any implementation upgrade.

### Network-config refactor (maintainability)

ETH zaps now support a declarative network config model (instead of maintaining forked per-network logic): `src/zap/upgradeable/config/EthZapNetworkConfig.sol` provides chain-specific addresses/capabilities, and `GenesisETHZap_v5` / `MinterETHZap_v4` load that config in their constructors. This keeps one primary code path while allowing chain-specific behavior (for example wrapped-collateral-only environments).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Access to RPC endpoints for any target networks you deploy to (mainnet and/or megaeth)
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

Primary entrypoints:
- `script/deploy-zaps-salted` (CREATE3 via BaoFactory; state-driven, recommended)
- `script/deploy-genesiseth-zap-unsalted.sh`
- `script/deploy-genesisusdc-zap-unsalted.sh`
- `script/deploy-mintereth-zap-unsalted.sh`
- `script/deploy-minterusdc-zap-unsalted.sh`
- `script/verify-zaps.sh` (mainnet verify helper)
- `script/verify-zaps-megaeth` (megaeth verify helper; etherscan default, blockscout optional)

Legacy implementation scripts are preserved in `script/archive/`; the `*-salted` and `*-unsalted`
entrypoints are thin wrappers that call into that archive.

### Network Config

Both salted and unsalted flows are network-aware:
- `mainnet` uses `deployments/mainnet/zap-addresses.json` and `MAINNET_RPC_URL`
- `megaeth` uses `deployments/megaeth/zap-addresses.json` and `MEGAETH_RPC_URL`

The unsalted scripts use `script/_zap-deploy-env.sh` and support:
- `ZAP_NETWORK=mainnet|megaeth` (default `mainnet`)
- `ZAP_CONFIG_FILE=<path>` (optional config override)
- `ZAP_RPC_URL=<url>` (optional direct RPC override)

### Salted CREATE3 Deploys (Recommended)

`script/deploy-zaps-salted` supports:
- `--deploy` (implementation + proxy)
- `--deploy-impl` (implementation only)
- `--check` (predict + on-chain check)
- `--verify` / `--verify-impl`

Required inputs:
- `--network <network>` where `<network>` is a `foundry.toml` rpc alias (for example `mainnet`, `megaeth`)
- deploy signer via `PRIVATE_KEY` or `--account <keystore-name>` for deploy modes
- `OWNER` or `.owner` in config

Useful options:
- `--market <MARKET>` to load zap addresses from config and auto-run minter post-config
  (`setStabilityPoolAllowed` + `transferOwnership`)
- `--salt <prefix>` to control CREATE3 proxy namespace
- `--config <path>` to override `deployments/<network>/zap-addresses.json`

Salt format:
- `<salt-prefix>::<zap-key>::zap`
- if `--market` is set, zap key includes market suffix
- for MegaETH you can use `--salt mega_test_v1` (your current flow)

State files:
- default salt (`harbor_v1`): `deployments/<network>/zaps.json`
- custom salt: `deployments/<network>/zaps-<salt>.json`

State file tracks:
- `predictions`: predicted proxy address per zap key + salt + `hasCode` + `checkedAt`
- `implementations`: all deployed implementations (multiple per zap key are expected over time)
- `proxies`: active deployed proxy records (salted deterministic addresses)

Prediction behavior:
- `--check` records predicted proxy addresses in `predictions`
- predictions are CREATE3 proxy predictions (deterministic); implementation addresses are CREATE/non-deterministic and not predicted

### One-Liners

Mainnet salted deploy (all zaps for a market):
```bash
PRIVATE_KEY=0x... MAINNET_RPC_URL=... ./script/deploy-zaps-salted --network mainnet --market GOLD --deploy
```

MegaETH salted deploy with custom salt:
```bash
PRIVATE_KEY=0x... MEGAETH_RPC_URL=... ./script/deploy-zaps-salted --network megaeth --market BTC --salt mega_test_v1 --deploy
```

MegaETH prediction/check only:
```bash
MEGAETH_RPC_URL=... ./script/deploy-zaps-salted --network megaeth --market BTC --salt mega_test_v1 --check
```

### Verification

Mainnet:
```bash
ETHERSCAN_API_KEY=... MAINNET_RPC_URL=... ./script/verify-zaps.sh
```

MegaETH (etherscan API mode, default):
```bash
ETHERSCAN_API_KEY=... MEGAETH_RPC_URL=... ./script/verify-zaps-megaeth --salt mega_test_v1
```

MegaETH (blockscout mode):
```bash
MEGAETH_RPC_URL=... ./script/verify-zaps-megaeth --salt mega_test_v1 --verifier blockscout
```

### Unsalted Per-Zap Deploys

Use the `*-unsalted` scripts when you want a direct one-off per-zap deploy JSON output under
`deployments/<network>/<YYYY-MM-DD>/` rather than CREATE3 salted orchestration.

Examples:
```bash
ZAP_NETWORK=mainnet MARKET=GOLD PRIVATE_KEY=0x... ./script/deploy-genesiseth-zap-unsalted.sh
ZAP_NETWORK=megaeth MARKET=BTC PRIVATE_KEY=0x... ./script/deploy-minterusdc-zap-unsalted.sh
```

## Post-Deployment

Notes:
- Ownership transfer is executed during deploy flows using configured `owner`.
- Salted minter deploys with `--market` apply stability pool allowlist + ownership transfer post-deploy.
- Re-runs reconcile state when proxies are already deployed, so interrupted runs can be resumed safely.

Optional follow-up (ETH zaps): update referral if needed:
```bash
cast send <ZAP_ADDRESS> "setReferral(address)" <NEW_REFERRAL> \
  --rpc-url <RPC_URL> \
  --private-key <PRIVATE_KEY>
```

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
│   ├── minter/          # Core contracts (Genesis_v1, Minter_v1, ReservePool_v1)
│   ├── zap/             # Zap contracts (upgradeable)
│   │   └── upgradeable/ # Upgradeable zap contracts (UUPS proxy)
│   └── util/            # Utility contracts (ReentrancyGuard, etc.)
├── test/                # Test files
├── script/              # Utility scripts
└── foundry.toml         # Foundry configuration
```

### Key Dependencies

- OpenZeppelin Contracts (upgradeable)
- Bao Base Contracts
- Forge Standard Library
### Where to find function-level examples

The previous long-form user flow examples were removed to keep this README operationally focused.
For integration examples and behavior coverage, use:
- `test/` (end-to-end and function-level expectations)
- zap interfaces in `src/interfaces/`
- deployment state outputs under `deployments/<network>/`

