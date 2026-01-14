# Production Deployment Addresses

This document contains the production contract addresses for Harbor Zap Contracts.

## BTC fxUSD
- **Genesis**: `0x42cc9a19b358a2A918f891D8a6199d8b05F0BC1C`
- **Minter**: `0x33e32ff4d0677862fa31582CC654a25b9b1e4888`
- **Zap Type**: `GenesisUSDCZap_v2` / `MinterUSDCZap_v2` (uses fxSAVE)

## BTC stETH
- **Genesis**: `0xc64Fc46eED431e92C1b5e24DC296b5985CE6Cc00`
- **Minter**: `0xF42516EB885E737780EB864dd07cEc8628000919`
- **Zap Type**: `GenesisETHZap_v3` / `MinterETHZap_v2` (uses wstETH)

## ETH fxUSD
- **Genesis**: `0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC`
- **Minter**: `0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F`
- **Zap Type**: `GenesisUSDCZap_v2` / `MinterUSDCZap_v2` (uses fxSAVE)

## EUR fxUSD
- **Genesis**: `0xa9EB43Ed6Ba3B953a82741F3e226C1d6B029699b`
- **Minter**: `0xDEFB2C04062350678965CBF38A216Cc50723B246`
- **Zap Type**: `GenesisUSDCZap_v2` / `MinterUSDCZap_v2` (uses fxSAVE)

## GOLD fxUSD
- **Genesis**: `0x2cbF457112Ef5A16cfcA10Fb173d56a5cc9DAa66`
- **Minter**: `0x880600E0c803d836E305B7c242FC095Eed234A8f`
- **Zap Type**: `GenesisUSDCZap_v2` / `MinterUSDCZap_v2` (uses fxSAVE)

---

## Environment Variables for Deployment

When deploying zap contracts using `script/deploy-zaps.sh`, set the following environment variables in `.env.local`:

```bash
# Required
RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY
PRIVATE_KEY=your_private_key_without_0x_prefix
OWNER=0xYourOwnerAddress
ETHERSCAN_API_KEY=your_etherscan_api_key  # Required for verification

# BTC fxUSD
GENESIS_BTC_FXUSD=0x42cc9a19b358a2A918f891D8a6199d8b05F0BC1C
MINTER_BTC_FXUSD=0x33e32ff4d0677862fa31582CC654a25b9b1e4888

# BTC stETH
GENESIS_BTC_STETH=0xc64Fc46eED431e92C1b5e24DC296b5985CE6Cc00
MINTER_BTC_STETH=0xF42516EB885E737780EB864dd07cEc8628000919

# ETH fxUSD
GENESIS_ETH_FXUSD=0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC
MINTER_ETH_FXUSD=0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F

# EUR fxUSD
GENESIS_EUR_FXUSD=0xa9EB43Ed6Ba3B953a82741F3e226C1d6B029699b
MINTER_EUR_FXUSD=0xDEFB2C04062350678965CBF38A216Cc50723B246

# GOLD fxUSD
GENESIS_GOLD_FXUSD=0x2cbF457112Ef5A16cfcA10Fb173d56a5cc9DAa66
MINTER_GOLD_FXUSD=0x880600E0c803d836E305B7c242FC095Eed234A8f

# Optional (defaults to Harbor referral)
REFERRAL_ETH=0x3dFc49e5112005179Da613BdE5973229082dAc35
```

## Usage

### Deploy Only
```bash
./script/deploy-zaps.sh
```

### Deploy and Verify
```bash
MODE=verify ./script/deploy-zaps.sh
```

### Verify Only (after deployment)
```bash
# Set all deployed contract addresses and ETHERSCAN_API_KEY, then:
MODE=verify-only ./script/deploy-zaps.sh
```

**Note**: These are production addresses on Ethereum mainnet. Use these addresses when deploying zap contracts for production use.

