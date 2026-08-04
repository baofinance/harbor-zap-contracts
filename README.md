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

See **Zap preview semantics** and **Adding a new zapper** below for integrator expectations and how to extend the tree (e.g. a new chain such as MegaETH).

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

For upgrade prep, use `script/dump-zap-storage-layout.sh` plus `extra_output = ["storageLayout"]` in `foundry.toml` to diff layouts before any implementation upgrade. See [docs/zap-storage-layout-upgrade.md](docs/zap-storage-layout-upgrade.md) and [docs/zap-v3-v4-migration.md](docs/zap-v3-v4-migration.md) for production v3/v4 → branch v4/v5 migration.

### Network-config refactor (maintainability)

Zaps use declarative network config libraries: `src/zap/upgradeable/config/StETHZapNetworkConfig.sol` for stETH / wstETH paths (`GenesisETHZap_v5`, `MinterETHZap_v4`) and `src/zap/upgradeable/config/FxUSDZapNetworkConfig.sol` for fxSAVE paths (`GenesisUSDCZap_v5`, `MinterUSDCZap_v4`). This keeps shared constants out of the concrete contracts while allowing chain-specific behavior (for example wrapped-collateral-only environments).

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

**Market integration (production minters + stability pools):** `test/MinterMarketForkIntegration.t.sol` forks mainnet, loads `deployments/mainnet/zap-addresses.json` (default market `BTC`), deploys v4 zaps against production minters, and zaps into each configured stability pool on both rails (ETH/stETH/wstETH and USDC/fxUSD/fxSAVE). Requires `MAINNET_RPC_URL`; runtime ~50s for the BTC suite.

## Zap preview semantics

Integrators should treat **previews as hints**, not guaranteed execution results, unless documented otherwise per function.

| Zap | Previews (wrapped / shares) | Notes |
|-----|----------------------------|--------|
| `GenesisETHZap_v5` | Lido + wstETH view math for ETH/stETH paths | On-chain views for balances / TVL where implemented |
| `GenesisUSDCZap_v5` | `IERC4626(fxSAVE).convertToShares` after **USDC→fxUSD $1 peg scaling** (base path) or nominal fxUSD amount (collateral path) | **Not** a static replay of the fxUSD diamond + router `convert` calldata. Live output can differ; always set `minWrappedCollateralOut`. fxSAVE’s ERC4626 `asset()` is the vault’s accounting asset (e.g. fxSP), not necessarily the zap’s `COLLATERAL_ASSET` address. |
| `MinterETHZap_v4` | Same family as Genesis ETH + minter `*DryRun` for mint / pool previews | — |
| `MinterUSDCZap_v4` | Same **convertToShares** model as Genesis USDC for the wrapped leg + minter dry-runs for pegged / leveraged / stability pool previews | Same diamond vs model caveat; use slippage parameters on zaps |

**Fork regression:** `test/GenesisUSDCZap_v5.t.sol` and `test/MinterUSDCZap_v4.t.sol` → `test_PreviewVsActualZap_WithinBpsTolerance` compare preview to **actual** zap wrapped-collateral output within **200 bps** (2%) relative tolerance (diamond path vs ERC4626 + peg model).

## Adding a new zapper (checklist)

Use this when supporting a **new chain or market** (example sketch: **MegaETH**, no native base asset, **USDM** collateral, **USDMY** wrapped collateral, **haUSD** pegged token). Names are illustrative; wire your real addresses and decimals.

### 1. Constants and network config

- Add or extend a library under `src/constants/<chain>/` (e.g. `MegaETHUsdmConstants.sol`) with token/router/diamond addresses and any chain-specific literals.
- Add or extend `src/zap/upgradeable/config/*ZapNetworkConfig.sol` (pattern: `StETHZapNetworkConfig`, `FxUSDZapNetworkConfig`):
  - `struct Config` with immutables the zaps need (base, collateral, wrapped, flags like `supportsBaseAsset`, router addresses, `bytes4` selectors if applicable).
  - `load(uint256 chainId)` **fail-closed** (return zeroed config or explicit unsupported) for unknown chains.

### 2. Conversion helpers (optional but recommended)

- If the asset path is shared across two zaps, add `src/zap/upgradeable/asset/<Flavor>ZapBase_v1.sol` (like `StETHZapBase_v1`, `FxUSDZapBase_v1`) with **internal** `_convert*` / `_preview*` / `_safeApprove` helpers and NatSpec on preview assumptions.

### 3. Concrete zap contracts

- Add `src/zap/upgradeable/<Name>Zap_v<N>.sol` (Genesis and Minter are separate products):
  - Inherit `GenesisZapBase_v1` and/or `MinterZapBase_v1` / `MinterZapShared_v1` where the deposit/mint pipeline matches existing zaps.
  - Constructor: load config, set **immutables**, assert `IGenesis(genesis).WRAPPED_COLLATERAL_TOKEN()` or `IMinter(minter).WRAPPED_COLLATERAL_TOKEN()` matches your wrapped token.
  - `_requireSupportedAsset`: allow only **base**, **collateral**, and **wrapped** addresses your zap supports (see `GenesisUSDCZap_v5` / `MinterETHZap_v4` for patterns).
  - Implement previews honestly: revert `PreviewNotSupported` if you cannot model the path, or document model vs diamond.

### 4. Interfaces

- Extend or add `src/interfaces/I<Your>Zap*.sol` so ABI consumers and tests share one surface.
- Document preview behavior in the interface `@dev` blocks (see `IGenesisZapV5Common`).

### 5. Tests

- Add `test/<Your>Zap_v<N>.t.sol` with `TestMinterSetUp` (or your harness), `vm.createSelectFork` using the RPC alias from `foundry.toml` (e.g. `megaeth`).
- Cover: happy-path zaps, preview vs actual (with tolerance if the model ≠ router), upgrade, rescue, fallback.

### 6. Scripts and deployments

- `deployments/<network>/zap-addresses.json` (and optional `zaps-<salt>.json` when using CREATE3).
- Wire **verify** paths in `script/verify-zaps.sh` / `script/verify-zaps-megaeth` (or a new script) with `impl_path` and constructor ABI matching your new contract.
- Add the contract name to `script/dump-zap-storage-layout.sh` when you need storage diffs for UUPS upgrades.

### 7. README and operators

- Link the new zapper in this file under **Contracts** / **Overview**.
- Document any new RPC env var in **Testing** and **Deployment** (already uses `MEGAETH_RPC_URL` for MegaETH examples).

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
- deploy signer for deploy modes: **`--account <keystore-name>` is preferred** (Foundry keystore, for example via `cast wallet import`); `PRIVATE_KEY` in the environment also works. One-liners below use `PRIVATE_KEY=0x...` only as a short example—use a keystore for real operations when you can.
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

## Security Considerations

- **Private Keys**: Never commit private keys to version control. Prefer a **keystore** (`cast wallet import`, then `--account <name>` on `forge` / `cast` and in these scripts where supported) instead of exporting `PRIVATE_KEY` in your shell.
- **Ownership**: Transfer ownership to a multisig or secure address after deployment
- **Lido referral (ETH zaps)**: `GenesisETHZap_v5` and `MinterETHZap_v4` pass a fixed referral into Lido `submit` from `StETHZapNetworkConfig` (implementation immutable). Integrators can read it via `referral()` on the native ETH zap interfaces. It is not owner-updatable on-chain; changing it means updating network config and deploying a new implementation (then upgrading the proxy if you use UUPS).
- **Access Control**: Zap contracts have owner-only functions for rescue operations

## Development

### Project Structure

```
harbor-zap-contracts/
├── src/
│   ├── interfaces/      # Zap interfaces (+ symlinks to shared harbor interfaces)
│   ├── minter/          # Symlinks into lib/harbor (test fixtures / forge linking)
│   ├── zap/             # Zap contracts (upgradeable)
│   │   └── upgradeable/ # Upgradeable zap contracts (UUPS proxy)
│   ├── constants/       # Chain address constants
│   └── util/            # Symlink into lib/harbor util (WordCodec)
├── lib/
│   ├── harbor/          # baofinance/harbor (Genesis/Minter/ReservePool + shared interfaces)
│   └── bao-base/        # Bao base + FactoryDeployer
├── test/                # Test files
├── script/              # FactoryDeployer CREATE3 deploy + legacy unsalted wrappers
├── package.json         # bao-base CI/tooling scripts
└── foundry.toml         # Foundry configuration
```

### Key Dependencies

- OpenZeppelin Contracts (upgradeable; via bao-base nested OZ for UUPS init / ReentrancyGuard compat)
- Bao Base Contracts (`HarborOwnable`, FactoryDeployer)
- `baofinance/harbor` (minter/genesis implementations for tests)
- Forge Standard Library

### Deploy (salted / CREATE3)

```bash
script/deploy.sh --network mainnet --market GOLD --genesis-usdc 0x...
# or: yarn deploy --network mainnet --market GOLD --genesis-usdc 0x...
```

Legacy unsalted bash wrappers (`script/*-unsalted.sh`) remain available as a fallback.
### Where to find function-level examples

The previous long-form user flow examples were removed to keep this README operationally focused.
For integration examples and behavior coverage, use:
- `test/` (end-to-end and function-level expectations)
- zap interfaces in `src/interfaces/`
- deployment state outputs under `deployments/<network>/`

