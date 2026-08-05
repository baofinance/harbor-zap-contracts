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

- `GenesisETHZap_v1`: Zap ETH or stETH into Genesis contracts (upgradeable)
- `MinterETHZap_v1`: Zap ETH or stETH to mint pegged or leveraged tokens, or deposit into Stability Pools (upgradeable)

### USDC/fxSAVE Zap Contracts

- `GenesisUSDCZap_v1`: Zap USDC or fxUSD into Genesis contracts (upgradeable)
- `MinterUSDCZap_v1`: Zap USDC or fxUSD to mint pegged or leveraged tokens, or deposit into Stability Pools (upgradeable)

## Operator notes

Current zap set (`GenesisETHZap_v1`, `GenesisUSDCZap_v1`, `MinterETHZap_v1`, `MinterUSDCZap_v1`) is a **new `_v1` implementation family** — deploy **new proxies**; do not UUPS-upgrade production v3/v4 proxies onto these implementations.

Safety envelope (aligned with harbor-swap executor hardening): `ZapIntake` exact/measured pulls + leftover refund, balance-delta mint checks, `TokenHolder_v2` owner sweep, reentrancy protection, allowlisted stability pools, and mint/share validation. Minter allowlists use ERC-7201 namespaced storage (no root slots).

For upgrade prep within the same `_v1` line, use `script/dump-zap-storage-layout.sh` plus `extra_output = ["storageLayout"]` in `foundry.toml`. See [docs/zap-storage-layout-upgrade.md](docs/zap-storage-layout-upgrade.md) and [docs/zap-v3-v4-migration.md](docs/zap-v3-v4-migration.md) for production v3/v4 → branch v1 migration.

### Network-config refactor (maintainability)

Zaps use declarative network config libraries: `src/zap/upgradeable/config/StETHZapNetworkConfig.sol` for stETH / wstETH paths (`GenesisETHZap_v1`, `MinterETHZap_v1`) and `src/zap/upgradeable/config/FxUSDZapNetworkConfig.sol` for fxSAVE paths (`GenesisUSDCZap_v1`, `MinterUSDCZap_v1`). This keeps shared constants out of the concrete contracts while allowing chain-specific behavior (for example wrapped-collateral-only environments).

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Access to RPC endpoints for any target networks you deploy to (mainnet and/or megaeth)
- Private key with sufficient ETH for gas fees

Optional local helpers `yarn foundryup` / `yarn uv:install` pipe the official Foundry/uv installers — run only on a trusted machine (same as upstream docs). CI uses the pinned Foundry action, not those scripts.

## Installation

1. Clone the repository (with submodules):
```bash
git clone --recurse-submodules <repository-url>
cd harbor-zap-contracts
```

2. Install Foundry libs and JS tooling (Yarn 4 via Corepack — needed for `yarn CI` / lint / slither):
```bash
forge install
corepack enable
yarn install
```

3. Build the contracts:
```bash
forge build
```

## Testing

```bash
forge test
# or: yarn test
```

For fork tests, set `MAINNET_RPC_URL` (e.g. in `.env.local`):
```bash
export MAINNET_RPC_URL="https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY"
forge test
```

Full bao-base CI (fmt, lint, slither, tests, coverage, sizes, validate):
```bash
# Bash 5+ on PATH (Homebrew bash on macOS)
yarn CI
```

**Market integration (production minters + stability pools):** `test/MinterMarketForkIntegration.t.sol` forks mainnet, loads `deployments/mainnet/zap-addresses.json` (default market `BTC`), deploys **v1** zaps against production minters, and zaps into each configured stability pool on both rails (ETH/stETH/wstETH and USDC/fxUSD/fxSAVE). Requires `MAINNET_RPC_URL`; suite CPU ~80s for the BTC suite (see `regression/gas-duration.txt`).

## Zap preview semantics

Integrators should treat **previews as hints**, not guaranteed execution results, unless documented otherwise per function.

| Zap | Previews (wrapped / shares) | Notes |
|-----|----------------------------|--------|
| `GenesisETHZap_v1` | Lido + wstETH view math for ETH/stETH paths | On-chain views for balances / TVL where implemented |
| `GenesisUSDCZap_v1` | `IERC4626(fxSAVE).convertToShares` after **USDC→fxUSD $1 peg scaling** (base path) or nominal fxUSD amount (collateral path) | **Not** a static replay of the fxUSD diamond + router `convert` calldata. Live output can differ; always set `minWrappedCollateralOut`. fxSAVE’s ERC4626 `asset()` is the vault’s accounting asset (e.g. fxSP), not necessarily the zap’s `COLLATERAL_ASSET` address. |
| `MinterETHZap_v1` | Same family as Genesis ETH + minter `*DryRun` for mint / pool previews | — |
| `MinterUSDCZap_v1` | Same **convertToShares** model as Genesis USDC for the wrapped leg + minter dry-runs for pegged / leveraged / stability pool previews | Same diamond vs model caveat; use slippage parameters on zaps |

**Fork regression:** `test/GenesisUSDCZap_v1.t.sol` and `test/MinterUSDCZap_v1.t.sol` → `test_PreviewVsActualZap_WithinBpsTolerance` compare preview to **actual** zap wrapped-collateral output within **200 bps** (2%) relative tolerance (diamond path vs ERC4626 + peg model).

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
  - `_requireSupportedAsset`: allow only **base**, **collateral**, and **wrapped** addresses your zap supports (see `GenesisUSDCZap_v1` / `MinterETHZap_v1` for patterns).
  - Implement previews honestly: revert `PreviewNotSupported` if you cannot model the path, or document model vs diamond.

### 4. Interfaces

- Extend or add `src/interfaces/I<Your>Zap*.sol` so ABI consumers and tests share one surface.
- Document preview behavior in the interface `@dev` blocks (see `IGenesisZapV1Common`).

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

**FactoryDeployer / CREATE3** (`yarn deploy` / `script/deploy.sh`):
```bash
script/deploy.sh --network mainnet --market GOLD --genesis-usdc 0x...
# or: yarn deploy --network mainnet --market GOLD --genesis-usdc 0x...
```
Requires `--network`, `--market`, and at least one of `--genesis-eth` / `--genesis-usdc` / `--minter-eth` / `--minter-usdc`. Uses `script/Deploy_Zaps.s.sol` + `HarborZapDeployStack` (bao-base FactoryDeployer). Deployer must be a BaoFactory operator. State lands in `deployments/state-<chainId>-<MARKET>.json` (salt prefix `harbor_zap_v1_<MARKET>`).

Historical address manifests live under `deployments/<network>/` (including dated JSON). **Verification:** `yarn deploy` / `script/deploy.sh` runs forge `--verify` by default (`--no-verify` to skip). `script/verify-zaps.sh` / `script/verify-zaps-megaeth` are backup re-verify helpers; manifests with `"skipVerify": true` exit successfully without submitting.

### Network Config

- `mainnet` → `deployments/mainnet/zap-addresses.json` + `MAINNET_RPC_URL`
- `megaeth` → `deployments/megaeth/zap-addresses.json` + `MEGAETH_RPC_URL`

**New-chain requirement — EIP-1153 (Cancun):** the zaps' reentrancy guard (`TokenHolder_v2` → OZ `ReentrancyGuardTransient`) uses transient storage (`TSTORE`/`TLOAD`). On a chain without EIP-1153, **every `nonReentrant` function reverts unconditionally** and no test in this repo would catch it. Before adding a chain to the config libraries, probe the RPC:

```bash
# succeeds (returns 0x) iff TSTORE is supported; fails with invalid opcode otherwise
cast call --rpc-url "$NEW_CHAIN_RPC_URL" --create 0x600160005d60006000f3
```

Mainnet and MegaETH are verified.

### One-liners

```bash
# Keystore required: cast wallet import deployer --interactive
MAINNET_RPC_URL=... yarn deploy --network mainnet --market GOLD --account deployer \
  --genesis-usdc 0x... --minter-usdc 0x...
```

### Verification

```bash
ETHERSCAN_API_KEY=... MAINNET_RPC_URL=... ./script/verify-zaps.sh
# mega_test_v1 is historical (skipVerify=true) — exits 0 with note; use a fresh state file for real re-verify
ETHERSCAN_API_KEY=... MEGAETH_RPC_URL=... ./script/verify-zaps-megaeth --salt mega_test_v1
```

## Post-Deployment

Notes:
- Proxies initialize with deployer as owner + Harbor multisig pending; `_transferAllOwnerships()` completes the handoff **in the same broadcast** (deployer confirms — the multisig never signs). Verify `owner()` on each proxy afterwards. If a run is interrupted before that step, resume **within 1 hour** of proxy init; the pending transfer expires after that and only a UUPS upgrade can hand off. Ownership is one-shot: after the handoff it can never be rotated.
- Stability pool allowlists are **not** auto-applied; configure `setStabilityPoolAllowed` separately after deploy.
- Re-runs skip proxies already recorded in state, so interrupted runs can be resumed safely.

## Security Considerations

- **Deploy signer**: `script/deploy.sh` is **keystore-only** (`cast wallet import`, then `--account <name>`). `PRIVATE_KEY` is rejected. Never commit keys or keystore passwords.
- **Ownership**: Handed to the Harbor multisig automatically during deploy (see Post-Deployment); one-shot — guard the multisig, it can never be rotated
- **Intake**: `ZapIntake` rejects fee-on-transfer / zero pulls (`pullExact`); stETH uses `pullMeasured` (allows 1–2 wei Lido rounding). Unspent input is refunded after convert legs.
- **Rescue**: Owner `sweep` / `rescueToken` via `TokenHolder_v2`; protected protocol tokens cannot be swept. Native rescue uses `call` (not `.transfer`).
- **Lido referral (ETH zaps)**: Fixed referral from `StETHZapNetworkConfig` (immutable). Readable via `referral()` on native ETH zap interfaces; changing it requires a new implementation. See [docs/zap-referral-config.md](docs/zap-referral-config.md).
- **Access Control**: Owner-only allowlist / rescue / UUPS upgrade

## Development

### Project Structure

```
harbor-zap-contracts/
├── src/
│   ├── interfaces/      # Zap-local interfaces (IGenesisZapV1*, IMinterZapV1*, …)
│   ├── zap/upgradeable/ # UUPS zaps + asset/base/config helpers + ZapIntake
│   └── constants/       # Chain address constants
├── lib/
│   ├── harbor/          # baofinance/harbor (test fixtures + shared interfaces)
│   └── bao-base/        # HarborOwnable, TokenHolder_v2, FactoryDeployer, CI scripts
├── test/                # @harborzap-test/… and @harbor/minter/… imports
├── docs/                # Storage layout + integrator migration notes
├── remappings.txt       # @harborzap/→src/; @harbor/→lib/harbor; bare src/minter|util→harbor
├── script/              # deploy.sh (FactoryDeployer) + verify helpers
├── package.json         # yarn CI / lint / slither / coverage / validate
└── foundry.toml
```

### Key Dependencies

- OpenZeppelin Contracts (upgradeable; via bao-base nested OZ for UUPS init / ReentrancyGuard compat)
- Bao Base (`HarborOwnable`, `TokenHolder_v2`, FactoryDeployer)
- `baofinance/harbor` (Genesis/Minter fixtures for tests)
- Forge Standard Library

### Where to find function-level examples

For integration examples and behavior coverage, use:
- `test/` (end-to-end and function-level expectations)
- zap interfaces in `src/interfaces/`
- deployment state outputs under `deployments/<network>/`

