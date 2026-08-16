# Zap integrator migration guide: production v3/v4 → branch v1

Production mainnet today uses **Minter v3** and **Genesis v4**. The `refactor-upgradeable` branch ships a **new `_v1` implementation family** (Minter + Genesis ETH/USDC). Core zap math is preserved; the integration surface is not backward compatible.

Deploy branch v1 as **new proxies**. See [zap-storage-layout-upgrade.md](./zap-storage-layout-upgrade.md) for why in-place UUPS upgrade is unsafe.

---

## Summary by contract

| Contract | API change severity | Indexer change | Notes |
|----------|--------------------|----------------|-------|
| `MinterUSDCZap_v1` | Low–medium | Medium | Same function names; removed legacy getters; previews no longer revert |
| `GenesisUSDCZap_v1` | Low | Low–medium | Same entrypoints; event adds two trailing zero fields |
| `MinterETHZap_v1` | **High** | Medium | Renamed ETH entrypoints; new slippage args |
| `GenesisETHZap_v1` | **High** | **High** | Renamed ETH entrypoint; event shape changed; param reorder |

---

## MinterETHZap_v3 → MinterETHZap_v1

### Function renames (ETH payable paths)

| production v3 | branch v1 |
|----|-----|
| `zapBaseAssetToPegged(receiver, minPeggedOut)` | `zapNativeAssetToPegged(minWrappedCollateralOut, receiver, minPeggedOut)` |
| `zapBaseAssetToLeveraged(receiver, minLeveragedOut)` | `zapNativeAssetToLeveraged(minWrappedCollateralOut, receiver, minLeveragedOut)` |
| `zapBaseAssetToStabilityPool(receiver, minPeggedOut, pool, minPoolOut)` | `zapNativeAssetToStabilityPool(minWrappedOut, receiver, minPeggedOut, pool, minPoolOut)` |

### New slippage parameter (collateral paths)

All `zapCollateralTo*` and collateral `*WithPermit` functions gain `minWrappedCollateralOut` as the second argument (after `collateralAmount`). Use `0` for v3-equivalent behavior (skip wrap-leg check).

### Initialization

| production v3 | branch v1 |
|----|-----|
| `initialize(deployerOwner, pendingOwner, referral_)` | `initialize(deployerOwner, pendingOwner)` |

### Removed owner / referral API

| Removed | Replacement |
|---------|-------------|
| `setReferral(address)` | None — referral is immutable from `StETHZapNetworkConfig` |
| Mutable `referral` storage | `referral()` view returns `DEFAULT_REFERRAL` immutable |
| `ReferralUpdated` event | None |

Production deployments passed `referral = address(0)` at deploy, which resolved to `WstETHConstants.DEFAULT_REFERRAL` (`0x3dFc49e5112005179Da613BdE5973229082dAc35`). Branch `_v1` uses the same address via config. See [zap-referral-config.md](./zap-referral-config.md).

### Events

| production v3 | branch v1 |
|----|-----|
| `BaseAssetZappedToLeverage(...)` | `BaseAssetZappedToLeveraged(...)` — **new topic** |

Other minter zap events keep the same field layout (now emitted from `MinterZapBase_v1`).

### Errors

| production v3 | branch v1 |
|----|-----|
| `MintFailed()` | `MintMismatchExpected(uint256 expected, uint256 received)` |
| `SlippageExceeded()` | `SlippageTooHighWrappedCollateral(uint256 received, uint256 minimum)` |
| `CollateralMismatch(...)` | `WrappedCollateralMismatch(...)` |

---

## MinterUSDCZap_v3 → MinterUSDCZap_v1

### Entrypoints

All `zapBaseAssetTo*`, `zapCollateralTo*`, permit variants, previews, rescue, and allowlist functions keep the **same selectors and argument order**.

### Removed getters

| production v3 | branch v1 |
|----|-----|
| `USDC()` | Use `BASE_ASSET()` |
| `FXUSD()` | Use `COLLATERAL_ASSET()` |
| `FXSAVE()` | Use `WRAPPED_COLLATERAL_ASSET()` |
| `FXUSD_DIAMOND()` | Use `COLLATERAL_MANAGER()` |
| `FXUSD_SWAP_ROUTER()` | Use `SWAP_ROUTER()` |

### Previews (behavioral change)

v3 stubbed eight preview functions with `FunctionNotFound()`. Branch `_v1` returns ERC4626 + minter dry-run model values. **Previews are hints, not quotes** — live diamond `convert` can diverge (~2% per fork tests). Always set `minWrappedCollateralOut` on zaps.

### Events / errors

Same changes as Minter ETH (`BaseAssetZappedToLeveraged`, `MintMismatchExpected`, `SlippageTooHighWrappedCollateral`).

---

## GenesisETHZap_v4 → GenesisETHZap_v1

### Function renames

| production v4 | branch v1 |
|----|-----|
| `zapBaseAsset(receiver, minWst, minBaseEquiv)` payable | `zapNativeAsset(receiver, minWst, minBaseEquiv)` payable |

### Param reorder (collateral)

| production v4 ETH | branch `_v1` (unified with USDC) |
|-------------------|----------------------------------|
| `zapCollateral(amount, receiver, minWst)` | `zapCollateral(amount, minWst, receiver)` |
| `zapCollateralWithPermit(amount, receiver, minWst, ...)` | `zapCollateralWithPermit(amount, minWst, receiver, ...)` |

### Initialization / referral

Same pattern as Minter ETH: `initialize` drops `referral_`; `setReferral` removed; `referral()` reads immutable config.

### Events (breaking for indexers)

**production v4 ETH** (6 data fields, no `genesis` topic):

```solidity
event ZappedBaseAsset(address indexed user, address indexed receiver, uint256 baseAssetIn, uint256 genesisSharesOut, uint256 baseAssetValueNow, uint256 collateralValueNow);
```

**branch `_v1`** (`GenesisETHZap_v1` — 8 fields, `genesis` indexed, explicit wrapped + shares):

```solidity
event ZappedBaseAsset(address indexed user, address indexed genesis, address indexed receiver, uint256 baseAssetIn, uint256 wrappedCollateralOut, uint256 sharesOut, uint256 baseAssetValueNow, uint256 collateralValueNow);
```

`ZappedCollateral` follows the same `_v1` shape. Update subgraph topic handlers and field decoders.

---

## GenesisUSDCZap_v4 → GenesisUSDCZap_v1

### Entrypoints

`zapBaseAsset`, `zapCollateral`, and permit variants are **unchanged**.

### Previews

Production v4 stubbed balance/TVL views and most previews with `FunctionNotFound()`. Branch `_v1` implements previews; unsupported balance views revert `PreviewNotSupported()` instead.

### Events

Branch `_v1` adds `baseAssetValueNow = 0` and `collateralValueNow = 0` to USDC zap events for parity with the ETH zap event shape.

---

## Deployment

Use `yarn deploy` / `script/deploy.sh` (FactoryDeployer) against the `_v1` contracts. Historical manifests under `deployments/` remain for address lookup / verify helpers.

Constructor args:

- ETH zaps: `(minter_)` or `(genesis_)` only — no `referral_`.
- USDC zaps: unchanged `(minter_)` / `(genesis_)`.

Initialize with two args: `initialize(deployerOwner, pendingOwner)`.

---

## Frontend checklist

- [ ] Branch on zap type: ETH minter/genesis use `zapNativeAsset*` / `zapNativeAsset`, not `zapBaseAsset*`.
- [ ] Add `minWrappedCollateralOut` to ETH minter collateral zaps (use `0` to match legacy behavior).
- [ ] Reorder Genesis ETH collateral call args to `(amount, minWst, receiver)`.
- [ ] Stop calling `setReferral`; read `referral()` for display only.
- [ ] Replace removed USDC getters with generic `BASE_ASSET` / `COLLATERAL_ASSET` / `WRAPPED_COLLATERAL_ASSET`.
- [ ] Treat USDC previews as estimates; keep slippage params on transactions.
- [ ] Update error decoders for renamed/reparameterized errors.

## Indexer checklist

- [ ] Subscribe to `BaseAssetZappedToLeveraged` (not `BaseAssetZappedToLeverage`).
- [ ] Migrate Genesis ETH `ZappedBaseAsset` / `ZappedCollateral` handlers to `_v1` 8-field layout.
- [ ] Drop `ReferralUpdated` subscription.
- [ ] Handle Genesis USDC events with two additional trailing uint fields (zeros).

## Error selector reference

Import `IZapErrors` from `src/interfaces/IZapErrors.sol`. Use qualified reverts: `revert IZapErrors.ZeroAmount()`.

Key renames from production:

| Production | Branch |
|------------|--------|
| `MintFailed()` | `MintMismatchExpected(uint256,uint256)` |
| `SlippageExceeded()` | `SlippageTooHighWrappedCollateral(uint256,uint256)` |
| `CollateralMismatch(address,address)` | `WrappedCollateralMismatch(address,address)` |
| `FunctionNotFound()` (USDC preview stubs) | Previews return values; balance stubs → `PreviewNotSupported()` |
