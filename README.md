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

## Zap contracts: review verdict and possible optimizations

**Verdict (current `GenesisETHZap_v5`, `GenesisUSDCZap_v5`, `MinterETHZap_v4`, `MinterUSDCZap_v4`):** The four upgradeable zaps are in good shape to keep as-is for production. They prioritize safety (balance-delta checks, slippage minima, reentrancy protection, stability pool allowlisting, mint/share validation) over micro-gas tuning. User-visible cost is dominated by external calls (Lido, fx routes, Minter mint, Stability Pool), not small internal refactors.

**Possible optimizations (optional; for a later pass or lead review):**

1. **Genesis ETH previews** — `previewSharesFromBase` / `previewSharesFromCollateral` call `this.previewWrappedCollateralFromBase` / `this.previewWrappedCollateralFromCollateral` (external self-calls). Replacing those with shared **internal** helpers would save a modest amount of gas and bytecode; behavior stays the same.
2. **Genesis ETH `zapBaseAsset`** — `_getCurrentValuesBaseCollateral` may be used twice in the same transaction (slippage check and event). **Reusing one in-memory tuple** would avoid duplicate oracle-style view work; impact is minor on L1.
3. **Cross-zap deduplication** — `MinterETHZap_v4` and `MinterUSDCZap_v4` share parallel patterns (`_mintPeggedToken`, `_depositToStabilityPool`, parts of `_zapToPegged`, etc.). A **library or shared base** could reduce drift and audit surface; treat as a **maintainability** refactor with full storage-layout and upgrade checks, not as an urgent gas win.
4. **Profiling first** — Any deeper optimization should be driven by traces/profiling on representative txs; contract internals are unlikely to beat the cost of external protocols.

**Related:** Storage layout for upgrades is documented via `__gap` on these zaps, `extra_output = ["storageLayout"]` in `foundry.toml`, and `script/dump-zap-storage-layout.sh` for human-readable layout dumps before upgrades.

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

UUPS deployments are handled by per-zap scripts:
- `script/deploy-genesiseth-zap.sh` (requires `GENESIS_ETH`)
- `script/deploy-genesisusdc-zap.sh` (requires `GENESIS_USDC`)
- `script/deploy-mintereth-zap.sh` (requires `MINTER_ETH`)
- `script/deploy-minterusdc-zap.sh` (requires `MINTER_USDC`)
- `script/verify-zaps.sh` (verifies deployment JSONs)

Salted CREATE3 deployments (BaoFactory) are handled by:
- `script/deploy-zaps` (writes `deployments/<network>/zaps[-<salt>].json`)

All scripts require `MAINNET_RPC_URL` and `PRIVATE_KEY`. Ownership is taken from
`deployments/mainnet/zap-addresses.json` (`owner`) or `OWNER` env. ETH zaps also accept
optional `REFERRAL_ETH` (defaults to zero address, which uses the contract default).

You can provide zap target addresses via env vars or `deployments/mainnet/zap-addresses.json`:
- `GENESIS_ETH` or `markets.<MARKET>.addresses.genesisEth`
- `GENESIS_USDC` or `markets.<MARKET>.addresses.genesisUsdc`
- `MINTER_ETH` or `markets.<MARKET>.addresses.minterEth`
- `MINTER_USDC` or `markets.<MARKET>.addresses.minterUsdc`

The config file also supports:
- `owner` for final ownership transfer (initializer uses deployer)
- `markets.<MARKET>.stabilityPools`

Each deploy script writes a timestamped deployment file under
`deployments/mainnet/YYYY-MM-DD/` (UTC) so previous deployments are not overwritten.
If `DEPLOY_NOTE` is provided, it is stored in the JSON output.

Options:
- `MARKET`: `ETH`, `BTC`, `GOLD`, `SILVER`, `EUR`, `MCAP`
- Required env: `MAINNET_RPC_URL`, `PRIVATE_KEY`
- Verification env: `ETHERSCAN_API_KEY` (required for on-chain verification unless disabled)
- Optional env: `REFERRAL_ETH` (ETH zaps only)
- Optional env: `DEPLOY_NOTE` (free-form note stored in deployment JSON)
- Config file: `deployments/mainnet/zap-addresses.json` with `owner` and `markets.<MARKET>`
- Verification control: `VERIFY=true|false` and `VERIFY_REQUIRED=true|false` (default required)

Examples:
```bash
# Deploy GOLD ETH Genesis
MARKET=GOLD ./script/deploy-genesiseth-zap.sh

# Deploy GOLD USDC Minter
MARKET=GOLD ./script/deploy-minterusdc-zap.sh

# Deploy EUR ETH Genesis with a note
MARKET=EUR DEPLOY_NOTE="Deploy EUR wstETH genesis zap" ./script/deploy-genesiseth-zap.sh
```

## Post-Deployment

Notes:
- Ownership is transferred to `owner` from `zap-addresses.json` during deployment.
- Verification is performed during deployment when enabled. Use `script/verify-zaps.sh` if you skipped it.
- Ownership transfer must be completed within 1 hour (BaoOwnable pending owner window).

Optional follow-ups:

1. **Update Referral** (ETH zaps only, optional): Update Lido referral address if needed:
```bash
cast send <ZAP_ADDRESS> "setReferral(address)" <NEW_REFERRAL> \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

## Contract Addresses

### Mainnet (when deployed)

ETH/wstETH Zaps:
- GenesisETHZap_v5: TBD (upgradeable)
- MinterETHZap_v4: TBD (upgradeable)

USDC/fxSAVE Zaps:
- GenesisUSDCZap_v5: TBD (upgradeable)
- MinterUSDCZap_v4: TBD (upgradeable)

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

## Use Cases

### GenesisETHZap_v5: ETH and stETH Deposits

#### Bob deposits 10 ETH using `zapBaseAsset`

**Step 1: Preview the expected output**
```solidity
// First, use the preview function to calculate minWstEthOut
// Apply a small slippage buffer (e.g., 0.5-1%) to protect against MEV/front-running
uint256 ethAmount = 10 ether;
uint256 expectedWstEth = GenesisETHZap_v5(genesisZapAddress).previewWrappedCollateralFromBase(ethAmount);
uint256 minWrappedCollateralOut = (expectedWstEth * 99) / 100; // 1% slippage tolerance
```

**Step 2: Execute the zap**
```solidity
// The zap contract will:
// 1. Convert 10 ETH into ~10 stETH via Lido
// 2. Convert the ~10 stETH into ~8.1 wstETH (wstETH/stETH ratio < 1)
// 3. Deposit the 8.1 wstETH into Genesis for Bob
// Bob receives Genesis shares equal to the wstETH amount (1:1 ratio)

GenesisETHZap_v5(genesisZapAddress).zapBaseAsset{value: 10 ether}(
    bobAddress,                 // Receiver address (Bob)
    minWrappedCollateralOut,    // Minimum wrapped collateral expected (with slippage buffer)
    0                           // Optional base asset value floor (set 0 for no floor)
);
```

**Flow Summary:**
- **Input**: 10 ETH
- **Step 1**: 10 ETH → ~10 stETH (via Lido)
- **Step 2**: ~10 stETH → ~8.1 wstETH (wstETH exchange rate)
- **Step 3**: ~8.1 wstETH → 8.1 Genesis shares (1:1 deposit)
- **Output**: Bob receives 8.1 Genesis shares

#### Alice deposits 5 stETH using `zapCollateral`

**Step 1: Preview the expected output**
```solidity
uint256 stEthAmount = 5 ether;
uint256 expectedWstEth = GenesisETHZap_v5(genesisZapAddress).previewWrappedCollateralFromCollateral(stEthAmount);
uint256 minWstEthOut = (expectedWstEth * 995) / 1000; // 0.5% slippage tolerance
```

**Step 2: Approve and execute the zap**
```solidity
// 1. Approve the zap contract to spend stETH
IERC20(STETH).approve(genesisZapAddress, 5 ether);

// 2. Execute the zap
// The zap contract will:
// - Transfer 5 stETH from Alice
// - Convert 5 stETH into ~4.05 wstETH
// - Deposit the wstETH into Genesis for Alice

GenesisETHZap_v5(genesisZapAddress).zapCollateral(
    5 ether,         // Amount of stETH to zap
    minWstEthOut,    // Minimum wstETH expected
    aliceAddress     // Receiver address (Alice)
);
```

**Flow Summary:**
- **Input**: 5 stETH
- **Step 1**: 5 stETH → ~4.05 wstETH (wstETH exchange rate)
- **Step 2**: ~4.05 wstETH → 4.05 Genesis shares (1:1 deposit)
- **Output**: Alice receives 4.05 Genesis shares

#### Alice deposits 5 stETH using `zapCollateralWithPermit` (ERC-2612)

**Step 1: Preview the expected output**
```solidity
uint256 stEthAmount = 5 ether;
uint256 expectedWstEth = GenesisETHZap_v5(genesisZapAddress).previewWrappedCollateralFromCollateral(stEthAmount);
uint256 minWstEthOut = (expectedWstEth * 995) / 1000; // 0.5% slippage tolerance
```

**Step 2: Sign permit message off-chain and execute in one transaction**
```solidity
// Off-chain: Alice signs a permit message (no on-chain transaction needed)
// This is typically handled by wallets like MetaMask
bytes32 permitHash = _buildPermitHash(
    STETH,
    aliceAddress,
    genesisZapAddress,
    5 ether,
    deadline,
    nonce
);
(uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePrivateKey, permitHash);

// On-chain: Single transaction combines permit approval + zap execution
// No separate approve() transaction needed - saves gas!
GenesisETHZap_v5(genesisZapAddress).zapCollateralWithPermit(
    5 ether,         // Amount of stETH to zap
    minWstEthOut,    // Minimum wstETH expected
    aliceAddress,    // Receiver address (Alice)
    deadline,        // Permit signature deadline
    v, r, s          // Permit signature components
);
```

**Benefits of Permit:**
- ✅ **Gas savings**: Eliminates the need for a separate `approve()` transaction
- ✅ **Better UX**: Single transaction instead of two
- ✅ **Security**: Permit has built-in expiration (`deadline`) and nonce management

**Flow Summary:**
- **Input**: 5 stETH (approved via permit in same transaction)
- **Step 1**: 5 stETH → ~4.05 wstETH
- **Step 2**: ~4.05 wstETH → 4.05 Genesis shares
- **Output**: Alice receives 4.05 Genesis shares

### GenesisUSDCZap_v5: USDC and fxUSD Deposits

#### Bob deposits 10,000 USDC using `zapBaseAsset`

**Step 1: Calculate minimum fxSAVE output**
```solidity
// Note: The conversion rate from USDC to fxSAVE depends on the fxUSD Diamond contract
// fxSAVE is worth approximately 1.07 USDC, so 10,000 USDC converts to ~9,345.79 fxSAVE
// Apply a slippage buffer (0.5-1%) to protect against conversion rate changes

uint256 usdcAmount = 10_000 * 1e6; // 10k USDC (6 decimals)
// Calculate: 10,000 USDC / 1.07 = ~9,345.79 fxSAVE
uint256 estimatedFxSaveOut = (10_000 * 1e18 * 100) / 107; // ~9,345.79 fxSAVE (18 decimals)
uint256 minWrappedCollateralOut = (estimatedFxSaveOut * 99) / 100; // 1% slippage tolerance
```

**Step 2: Approve and execute the zap**
```solidity
// 1. Approve the zap contract to spend USDC
IERC20(USDC).approve(genesisZapAddress, 10_000 * 1e6);

// 2. Execute the zap
// The zap contract will:
// - Transfer 10,000 USDC from Bob
// - Convert 10,000 USDC → ~9,345.79 fxSAVE via fxUSD Diamond (fxSAVE ≈ 1.07 USDC)
// - Deposit the fxSAVE into Genesis for Bob
// Bob receives Genesis shares equal to the fxSAVE amount (1:1 ratio)

GenesisUSDCZap_v5(genesisZapAddress).zapBaseAsset(
    10_000 * 1e6,    // Amount of USDC (6 decimals)
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    bobAddress       // Receiver address (Bob)
);
```

**Flow Summary:**
- **Input**: 10,000 USDC
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE (via fxUSD Diamond conversion, fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → 9,345.79 Genesis shares (1:1 deposit)
- **Output**: Bob receives ~9,345.79 Genesis shares

#### Bob deposits 10,000 USDC using `zapBaseAssetWithPermit` (ERC-2612)

**Step 1: Calculate minimum fxSAVE output**
```solidity
uint256 usdcAmount = 10_000 * 1e6;
// Calculate: 10,000 USDC / 1.07 = ~9,345.79 fxSAVE
uint256 estimatedFxSaveOut = (10_000 * 1e18 * 100) / 107; // ~9,345.79 fxSAVE
uint256 minWrappedCollateralOut = (estimatedFxSaveOut * 995) / 1000; // 0.5% slippage tolerance
```

**Step 2: Sign permit message off-chain and execute in one transaction**
```solidity
// Off-chain: Bob signs a permit message for USDC (no on-chain transaction needed)
// This is typically handled by wallets like MetaMask
bytes32 permitHash = _buildPermitHash(
    USDC,
    bobAddress,
    genesisZapAddress,
    10_000 * 1e6,
    deadline,
    nonce
);
(uint8 v, bytes32 r, bytes32 s) = _signPermit(bobPrivateKey, permitHash);

// On-chain: Single transaction combines permit approval + zap execution
// No separate approve() transaction needed - saves gas!
GenesisUSDCZap_v5(genesisZapAddress).zapBaseAssetWithPermit(
    10_000 * 1e6,    // Amount of USDC
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    bobAddress,      // Receiver address (Bob)
    deadline,        // Permit signature deadline
    v, r, s          // Permit signature components
);
```

**Benefits of Permit:**
- ✅ **Gas savings**: Eliminates the need for a separate `approve()` transaction
- ✅ **Better UX**: Single transaction instead of two
- ✅ **Security**: Permit has built-in expiration (`deadline`) and nonce management

**Flow Summary:**
- **Input**: 10,000 USDC (approved via permit in same transaction)
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE (fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → 9,345.79 Genesis shares
- **Output**: Bob receives ~9,345.79 Genesis shares

#### Alice deposits 10,000 fxUSD using `zapCollateral`

**Step 1: Calculate minimum fxSAVE output**
```solidity
// Note: fxUSD to fxSAVE conversion rate depends on the fxUSD Diamond contract
// Since fxSAVE is worth approximately 1.07 USDC and fxUSD ≈ 1 USDC,
// 10,000 fxUSD converts to ~9,345.79 fxSAVE (10,000 / 1.07)

uint256 fxUsdAmount = 10_000 * 1e18; // 10k fxUSD (18 decimals)
// Calculate: 10,000 fxUSD / 1.07 = ~9,345.79 fxSAVE
uint256 estimatedFxSaveOut = (10_000 * 1e18 * 100) / 107; // ~9,345.79 fxSAVE (18 decimals)
uint256 minWrappedCollateralOut = (estimatedFxSaveOut * 99) / 100; // 1% slippage tolerance
```

**Step 2: Approve and execute the zap**
```solidity
// 1. Approve the zap contract to spend fxUSD
IERC20(FXUSD).approve(genesisZapAddress, 10_000 * 1e18);

// 2. Execute the zap
// The zap contract will:
// - Transfer 10,000 fxUSD from Alice
// - Convert 10,000 fxUSD → ~9,345.79 fxSAVE via fxUSD Diamond (fxSAVE ≈ 1.07 USDC)
// - Deposit the fxSAVE into Genesis for Alice

GenesisUSDCZap_v5(genesisZapAddress).zapCollateral(
    10_000 * 1e18,   // Amount of fxUSD (18 decimals)
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    aliceAddress     // Receiver address (Alice)
);
```

**Flow Summary:**
- **Input**: 10,000 fxUSD
- **Step 1**: 10,000 fxUSD → ~9,345.79 fxSAVE (via fxUSD Diamond conversion, fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → 9,345.79 Genesis shares (1:1 deposit)
- **Output**: Alice receives ~9,345.79 Genesis shares

#### Alice deposits 10,000 fxUSD using `zapCollateralWithPermit` (ERC-2612)

**Step 1: Calculate minimum fxSAVE output**
```solidity
uint256 fxUsdAmount = 10_000 * 1e18;
// Calculate: 10,000 fxUSD / 1.07 = ~9,345.79 fxSAVE
uint256 estimatedFxSaveOut = (10_000 * 1e18 * 100) / 107; // ~9,345.79 fxSAVE
uint256 minWrappedCollateralOut = (estimatedFxSaveOut * 995) / 1000; // 0.5% slippage tolerance
```

**Step 2: Sign permit message off-chain and execute in one transaction**
```solidity
// Off-chain: Alice signs a permit message for fxUSD (no on-chain transaction needed)
bytes32 permitHash = _buildPermitHash(
    FXUSD,
    aliceAddress,
    genesisZapAddress,
    10_000 * 1e18,
    deadline,
    nonce
);
(uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePrivateKey, permitHash);

// On-chain: Single transaction combines permit approval + zap execution
GenesisUSDCZap_v5(genesisZapAddress).zapCollateralWithPermit(
    10_000 * 1e18,   // Amount of fxUSD
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    aliceAddress,    // Receiver address (Alice)
    deadline,        // Permit signature deadline
    v, r, s          // Permit signature components
);
```

**Benefits of Permit:**
- ✅ **Gas savings**: Eliminates the need for a separate `approve()` transaction
- ✅ **Better UX**: Single transaction instead of two
- ✅ **Security**: Permit has built-in expiration (`deadline`) and nonce management

**Flow Summary:**
- **Input**: 10,000 fxUSD (approved via permit in same transaction)
- **Step 1**: 10,000 fxUSD → ~9,345.79 fxSAVE (fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → 9,345.79 Genesis shares
- **Output**: Alice receives ~9,345.79 Genesis shares

### MinterETHZap_v4: Mint Pegged and Leveraged Tokens

#### Bob deposits 10 ETH to mint pegged tokens using `zapBaseAssetToPegged`

**Step 1: Execute the zap**
```solidity
// ETH doesn't require approval - just send value with the transaction
// The zap contract will:
// - Convert 10 ETH → ~10 stETH via Lido
// - Convert ~10 stETH → ~8.1 wstETH (wstETH/stETH ratio < 1)
// - Mint pegged tokens using the Minter contract
// Apply slippage buffers: minWrappedCollateralOut (wstETH leg) and minPeggedOut (mint leg)
uint256 expectedWstEth = MinterETHZap_v4(minterZapAddress).previewWrappedCollateralFromBase(10 ether);
uint256 minWrappedOut = (expectedWstEth * 995) / 1000; // e.g. 0.5% on wrap
uint256 minPeggedOut = 8_000 * 1e18; // Minimum pegged tokens expected (adjust based on rates)
MinterETHZap_v4(minterZapAddress).zapBaseAssetToPegged{value: 10 ether}(
    minWrappedOut,   // Minimum wstETH from ETH→stETH→wrap (use 0 to skip wrap slippage check)
    bobAddress,      // Receiver address (Bob)
    minPeggedOut     // Minimum pegged tokens expected
);
```

**Flow Summary:**
- **Input**: 10 ETH
- **Step 1**: 10 ETH → ~10 stETH (via Lido)
- **Step 2**: ~10 stETH → ~8.1 wstETH (wstETH exchange rate)
- **Step 3**: ~8.1 wstETH → Pegged tokens (via Minter mint)
- **Output**: Bob receives pegged tokens

#### Bob deposits 10 ETH to mint leveraged tokens using `zapBaseAssetToLeveraged`

**Step 1: Execute the zap**
```solidity
// Similar flow but minting leveraged tokens instead
uint256 expectedWstEth = MinterETHZap_v4(minterZapAddress).previewWrappedCollateralFromBase(10 ether);
uint256 minWrappedOut = (expectedWstEth * 995) / 1000;
uint256 minLeveragedOut = 15_000 * 1e18; // Minimum leveraged tokens expected (leverage > 1)
MinterETHZap_v4(minterZapAddress).zapBaseAssetToLeveraged{value: 10 ether}(
    minWrappedOut,
    bobAddress,        // Receiver address (Bob)
    minLeveragedOut    // Minimum leveraged tokens expected
);
```

**Flow Summary:**
- **Input**: 10 ETH
- **Step 1**: 10 ETH → ~10 stETH → ~8.1 wstETH
- **Step 2**: ~8.1 wstETH → Leveraged tokens (via Minter mint with leverage)
- **Output**: Bob receives leveraged tokens

#### Alice deposits 5 stETH to mint pegged tokens using `zapCollateralToPegged`

**Step 1: Approve and execute the zap**
```solidity
// 1. Approve the zap contract to spend stETH
IERC20(STETH).approve(minterZapAddress, 5 ether);

// 2. Execute the zap
uint256 minPeggedOut = 4_000 * 1e18; // Minimum pegged tokens expected
MinterETHZap_v4(minterZapAddress).zapCollateralToPegged(
    5 ether,          // Amount of stETH
    0,                // minWrappedCollateralOut (wstETH slippage floor; 0 to skip)
    aliceAddress,     // Receiver address (Alice)
    minPeggedOut      // Minimum pegged tokens expected
);
```

**Flow Summary:**
- **Input**: 5 stETH
- **Step 1**: 5 stETH → ~4.05 wstETH (wstETH exchange rate)
- **Step 2**: ~4.05 wstETH → Pegged tokens (via Minter mint)
- **Output**: Alice receives pegged tokens

#### Alice deposits 5 stETH to mint leveraged tokens using `zapCollateralToLeveraged`

**Step 1: Approve and execute the zap**
```solidity
IERC20(STETH).approve(minterZapAddress, 5 ether);
uint256 minLeveragedOut = 7_500 * 1e18; // Minimum leveraged tokens expected
MinterETHZap_v4(minterZapAddress).zapCollateralToLeveraged(
    5 ether,
    0, // minWrappedCollateralOut (0 to skip)
    aliceAddress,
    minLeveragedOut
);
```

**Flow Summary:**
- **Input**: 5 stETH
- **Step 1**: 5 stETH → ~4.05 wstETH
- **Step 2**: ~4.05 wstETH → Leveraged tokens (via Minter mint with leverage)
- **Output**: Alice receives leveraged tokens

#### Alice deposits 5 stETH with permit to mint pegged tokens using `zapCollateralToPeggedWithPermit`

**Step 1: Sign permit message off-chain and execute in one transaction**
```solidity
// Off-chain: Alice signs permit message for stETH
bytes32 permitHash = _buildPermitHash(
    STETH,
    aliceAddress,
    minterZapAddress,
    5 ether,
    deadline,
    nonce
);
(uint8 v, bytes32 r, bytes32 s) = _signPermit(alicePrivateKey, permitHash);

// On-chain: Single transaction combines permit + zap execution
uint256 minPeggedOut = 4_000 * 1e18;
MinterETHZap_v4(minterZapAddress).zapCollateralToPeggedWithPermit(
    5 ether,
    0, // minWrappedCollateralOut (0 to skip)
    aliceAddress,
    minPeggedOut,
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 5 stETH (approved via permit)
- **Step 1**: 5 stETH → ~4.05 wstETH
- **Step 2**: ~4.05 wstETH → Pegged tokens
- **Output**: Alice receives pegged tokens

#### Bob deposits 10 ETH to Stability Pool using `zapBaseAssetToStabilityPool`

**Step 1: Execute the zap**
```solidity
address stabilityPool = 0x...; // Stability pool address
uint256 expectedWstEth = MinterETHZap_v4(minterZapAddress).previewWrappedCollateralFromBase(10 ether);
uint256 minWrappedOut = (expectedWstEth * 995) / 1000; // wstETH leg slippage (use 0 to skip)
uint256 minPeggedOut = 8_000 * 1e18; // Minimum pegged tokens from minting (accounts for mint fees)
// Note: Stability pool deposits don't incur fees, so minStabilityPoolOut should equal minPeggedOut
// Add only a small slippage buffer (0.1-0.5%) for rounding protection
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000; // 0.1% slippage buffer

MinterETHZap_v4(minterZapAddress).zapBaseAssetToStabilityPool{value: 10 ether}(
    minWrappedOut,        // Minimum wstETH from ETH→wrap
    bobAddress,           // Receiver address (Bob)
    minPeggedOut,         // Minimum pegged tokens expected (accounts for mint fees)
    stabilityPool,        // Stability pool address
    minStabilityPoolOut   // Minimum deposited into stability pool (should equal peggedOut, minus small rounding buffer)
);
```

**Flow Summary:**
- **Input**: 10 ETH
- **Step 1**: 10 ETH → ~10 stETH → ~8.1 wstETH
- **Step 2**: ~8.1 wstETH → Pegged tokens (via Minter mint, fees incurred here)
- **Step 3**: Pegged tokens → Deposited into Stability Pool (no fees on deposit)
- **Output**: Bob receives Stability Pool deposit (full pegged amount minus mint fees only)

#### Alice deposits 5 stETH to Stability Pool using `zapCollateralToStabilityPoolWithPermit`

**Step 1: Sign permit and execute**
```solidity
address stabilityPool = 0x...;
uint256 minPeggedOut = 4_000 * 1e18; // Minimum pegged tokens from minting (accounts for mint fees)
// Note: Stability pool deposits don't incur fees, so minStabilityPoolOut should equal minPeggedOut
// Add only a small slippage buffer (0.1-0.5%) for rounding protection
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000; // 0.1% slippage buffer

// Off-chain permit signing (similar to above)
// ...

MinterETHZap_v4(minterZapAddress).zapCollateralToStabilityPoolWithPermit(
    5 ether,
    0, // minWrappedCollateralOut (0 to skip)
    aliceAddress,
    minPeggedOut,         // Minimum pegged tokens expected (accounts for mint fees)
    stabilityPool,
    minStabilityPoolOut,  // Minimum deposited (should equal peggedOut, minus small rounding buffer)
    deadline,
    v, r, s
);
```

#### Alice deposits 5 wstETH to Stability Pool using `zapWrappedCollateralToStabilityPool`

```solidity
uint256 wstEthAmount = 5 ether;
uint256 minPeggedOut = MinterETHZap_v4(minterZapAddress).previewStabilityPoolFromWrappedCollateral(wstEthAmount);
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000;

IERC20(WSTETH).approve(minterZapAddress, wstEthAmount);
MinterETHZap_v4(minterZapAddress).zapWrappedCollateralToStabilityPool(
    wstEthAmount,
    aliceAddress,
    minPeggedOut,
    stabilityPool,
    minStabilityPoolOut
);
```

#### Alice deposits 5 wstETH to Stability Pool using `zapWrappedCollateralToStabilityPoolWithPermit`

```solidity
uint256 wstEthAmount = 5 ether;
uint256 minPeggedOut = MinterETHZap_v4(minterZapAddress).previewStabilityPoolFromWrappedCollateral(wstEthAmount);
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000;

// Permit signature created off-chain for WSTETH
MinterETHZap_v4(minterZapAddress).zapWrappedCollateralToStabilityPoolWithPermit(
    wstEthAmount,
    aliceAddress,
    minPeggedOut,
    stabilityPool,
    minStabilityPoolOut,
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 5 wstETH (approved via permit)
- **Step 1**: 5 wstETH → Pegged tokens (via Minter mint, fees incurred here)
- **Step 2**: Pegged tokens → Deposited into Stability Pool (no fees on deposit)
- **Output**: Alice receives Stability Pool deposit (full pegged amount minus mint fees only)

### MinterUSDCZap_v4: Mint Pegged and Leveraged Tokens

#### Bob deposits 10,000 USDC to mint pegged tokens using `zapBaseAssetToPegged`

**Step 1: Approve and execute the zap**
```solidity
// 1. Approve the zap contract to spend USDC
IERC20(USDC).approve(minterZapAddress, 10_000 * 1e6);

// 2. Execute the zap
// The zap contract will:
// - Transfer 10,000 USDC from Bob
// - Convert 10,000 USDC → ~9,345.79 fxSAVE via fxUSD Diamond (fxSAVE ≈ 1.07 USDC)
// - Mint pegged tokens using the Minter contract

uint256 minWrappedCollateralOut = 9_300 * 1e18; // Minimum wrapped collateral (fxSAVE) expected
uint256 minPeggedOut = 9_000 * 1e18; // Minimum pegged tokens expected
MinterUSDCZap_v4(minterZapAddress).zapBaseAssetToPegged(
    10_000 * 1e6,     // Amount of USDC (6 decimals)
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    bobAddress,       // Receiver address (Bob)
    minPeggedOut      // Minimum pegged tokens expected
);
```

**Flow Summary:**
- **Input**: 10,000 USDC
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE (fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens (via Minter mint)
- **Output**: Bob receives pegged tokens

#### Bob deposits 10,000 USDC to mint pegged tokens using `zapBaseAssetToPeggedWithPermit` (ERC-2612)

**Step 1: Sign permit and execute in one transaction**
```solidity
// Off-chain: Bob signs permit message for USDC
bytes32 permitHash = _buildPermitHash(
    USDC,
    bobAddress,
    minterZapAddress,
    10_000 * 1e6,
    deadline,
    nonce
);
(uint8 v, bytes32 r, bytes32 s) = _signPermit(bobPrivateKey, permitHash);

// On-chain: Single transaction
uint256 minWrappedCollateralOut = 9_300 * 1e18;
uint256 minPeggedOut = 9_000 * 1e18;
MinterUSDCZap_v4(minterZapAddress).zapBaseAssetToPeggedWithPermit(
    10_000 * 1e6,
    minWrappedCollateralOut,
    bobAddress,
    minPeggedOut,
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 10,000 USDC (approved via permit)
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens
- **Output**: Bob receives pegged tokens

#### Bob deposits 10,000 USDC to mint leveraged tokens using `zapBaseAssetToLeveraged`

**Step 1: Approve and execute the zap**
```solidity
IERC20(USDC).approve(minterZapAddress, 10_000 * 1e6);
uint256 minWrappedCollateralOut = 9_300 * 1e18;
uint256 minLeveragedOut = 18_000 * 1e18; // Minimum leveraged tokens expected (leverage > 1)
MinterUSDCZap_v4(minterZapAddress).zapBaseAssetToLeveraged(
    10_000 * 1e6,
    minWrappedCollateralOut,
    bobAddress,
    minLeveragedOut
);
```

**Flow Summary:**
- **Input**: 10,000 USDC
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE
- **Step 2**: ~9,345.79 fxSAVE → Leveraged tokens (via Minter mint with leverage)
- **Output**: Bob receives leveraged tokens

#### Alice deposits 10,000 fxUSD to mint pegged tokens using `zapCollateralToPegged`

**Step 1: Approve and execute the zap**
```solidity
IERC20(FXUSD).approve(minterZapAddress, 10_000 * 1e18);
uint256 minWrappedCollateralOut = 9_300 * 1e18;
uint256 minPeggedOut = 9_000 * 1e18;
MinterUSDCZap_v4(minterZapAddress).zapCollateralToPegged(
    10_000 * 1e18,    // Amount of fxUSD (18 decimals)
    minWrappedCollateralOut, // Minimum wrapped collateral (fxSAVE) expected
    aliceAddress,     // Receiver address (Alice)
    minPeggedOut      // Minimum pegged tokens expected
);
```

**Flow Summary:**
- **Input**: 10,000 fxUSD
- **Step 1**: 10,000 fxUSD → ~9,345.79 fxSAVE (fxSAVE ≈ 1.07 USDC)
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens (via Minter mint)
- **Output**: Alice receives pegged tokens

#### Alice deposits 10,000 fxUSD to mint pegged tokens using `zapCollateralToPeggedWithPermit` (ERC-2612)

**Step 1: Sign permit and execute**
```solidity
// Off-chain permit signing
// ...

MinterUSDCZap_v4(minterZapAddress).zapCollateralToPeggedWithPermit(
    10_000 * 1e18,
    minWrappedCollateralOut,
    aliceAddress,
    minPeggedOut,
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 10,000 fxUSD (approved via permit)
- **Step 1**: 10,000 fxUSD → ~9,345.79 fxSAVE
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens
- **Output**: Alice receives pegged tokens

#### Bob deposits 10,000 USDC to Stability Pool using `zapBaseAssetToStabilityPoolWithPermit`

**Step 1: Sign permit and execute**
```solidity
address stabilityPool = 0x...;
uint256 minWrappedCollateralOut = 9_300 * 1e18; // Minimum wrapped collateral (fxSAVE) expected
uint256 minPeggedOut = 9_000 * 1e18; // Minimum pegged tokens from minting (accounts for mint fees)
// Note: Stability pool deposits don't incur fees, so minStabilityPoolOut should equal minPeggedOut
// Add only a small slippage buffer (0.1-0.5%) for rounding protection
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000; // 0.1% slippage buffer

// Off-chain permit signing
// ...

MinterUSDCZap_v4(minterZapAddress).zapBaseAssetToStabilityPoolWithPermit(
    10_000 * 1e6,
    minWrappedCollateralOut,
    bobAddress,
    minPeggedOut,         // Minimum pegged tokens expected (accounts for mint fees)
    stabilityPool,
    minStabilityPoolOut,  // Minimum deposited (should equal peggedOut, minus small rounding buffer)
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 10,000 USDC (approved via permit)
- **Step 1**: 10,000 USDC → ~9,345.79 fxSAVE
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens (via Minter mint, fees incurred here)
- **Step 3**: Pegged tokens → Deposited into Stability Pool (no fees on deposit)
- **Output**: Bob receives Stability Pool deposit (full pegged amount minus mint fees only)

#### Alice deposits 10,000 fxUSD to Stability Pool using `zapCollateralToStabilityPoolWithPermit`

**Step 1: Sign permit and execute**
```solidity
address stabilityPool = 0x...;
uint256 minWrappedCollateralOut = 9_300 * 1e18; // Minimum wrapped collateral (fxSAVE) expected
uint256 minPeggedOut = 9_000 * 1e18; // Minimum pegged tokens from minting (accounts for mint fees)
// Note: Stability pool deposits don't incur fees, so minStabilityPoolOut should equal minPeggedOut
// Add only a small slippage buffer (0.1-0.5%) for rounding protection
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000; // 0.1% slippage buffer

// Off-chain permit signing
// ...

MinterUSDCZap_v4(minterZapAddress).zapCollateralToStabilityPoolWithPermit(
    10_000 * 1e18,
    minWrappedCollateralOut,
    aliceAddress,
    minPeggedOut,         // Minimum pegged tokens expected (accounts for mint fees)
    stabilityPool,
    minStabilityPoolOut,  // Minimum deposited (should equal peggedOut, minus small rounding buffer)
    deadline,
    v, r, s
);
```

#### Alice deposits 10,000 fxSAVE to Stability Pool using `zapWrappedCollateralToStabilityPool`

```solidity
uint256 fxSaveAmount = 10_000 * 1e18;
uint256 minPeggedOut =
    MinterUSDCZap_v4(minterZapAddress).previewStabilityPoolFromWrappedCollateral(fxSaveAmount);
uint256 minStabilityPoolOut = (minPeggedOut * 999) / 1000;

IERC20(FXSAVE).approve(minterZapAddress, fxSaveAmount);
MinterUSDCZap_v4(minterZapAddress).zapWrappedCollateralToStabilityPool(
    fxSaveAmount,
    aliceAddress,
    minPeggedOut,
    stabilityPool,
    minStabilityPoolOut
);
```

Permit variant available: `zapWrappedCollateralToStabilityPoolWithPermit`.

```solidity
// Permit signature created off-chain for FXSAVE
MinterUSDCZap_v4(minterZapAddress).zapWrappedCollateralToStabilityPoolWithPermit(
    fxSaveAmount,
    aliceAddress,
    minPeggedOut,
    stabilityPool,
    minStabilityPoolOut,
    deadline,
    v, r, s
);
```

**Flow Summary:**
- **Input**: 10,000 fxUSD (approved via permit)
- **Step 1**: 10,000 fxUSD → ~9,345.79 fxSAVE
- **Step 2**: ~9,345.79 fxSAVE → Pegged tokens (via Minter mint, fees incurred here)
- **Step 3**: Pegged tokens → Deposited into Stability Pool (no fees on deposit)
- **Output**: Alice receives Stability Pool deposit (full pegged amount minus mint fees only)

## License

[Add your license here]

## Support

For issues or questions, please open an issue on GitHub.

