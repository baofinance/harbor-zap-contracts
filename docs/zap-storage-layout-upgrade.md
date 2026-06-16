# Zap storage layout: production v3/v4 vs branch v4/v5

Use this document before any UUPS implementation swap. Run `script/dump-zap-storage-layout.sh` after `forge build` to print the current branch layouts.

**Verdict: do not upgrade production v3 Minter or v4 Genesis proxies in-place to branch v4/v5 implementations.** Deploy new proxies per market.

## Why in-place upgrade is unsafe

1. **Removed `referral` storage** on ETH zaps — v3 Minter and v4 Genesis stored `address referral` at slot 0 (after ERC-7201 namespaced `BaoOwnable`). v4/v5 remove that slot and add `__gap`, shifting layout.
2. **New `__gap` arrays** — v4/v5 concrete contracts declare explicit gaps; production v3/v4 had none.
3. **Constants → constructor immutables** — network addresses moved from compile-time constants to constructor-set immutables (new implementation bytecode; not a storage migration by itself, but confirms this is a new implementation family).
4. **Inheritance change** — shared bases (`MinterZapBase_v1`, `GenesisZapBase_v1`, asset bases) alter the compiled contract; immutables and namespaced owner storage differ from monolithic v3/v4.

`BaoOwnable` uses ERC-7201 namespaced storage and is unchanged between versions. The incompatibility is in **contract-specific state** below.

## Production baseline (git `9f31d46^`)

| Contract | Contract-specific storage | Notes |
|----------|-------------------------|-------|
| `MinterETHZap_v3` | `referral` (slot 0), `allowedStabilityPools` (slot 1) | No `__gap` |
| `MinterUSDCZap_v3` | `allowedStabilityPools` (slot 0) | No `__gap` |
| `GenesisETHZap_v4` | `referral` (slot 0) | No `__gap` |
| `GenesisUSDCZap_v4` | *(none beyond inherited owner)* | No `__gap` |

## Branch v4/v5 (`forge inspect` output)

| Contract | Contract-specific storage |
|----------|---------------------------|
| `MinterETHZap_v4` | `allowedStabilityPools` (slot 0), `__gap[51]` (slot 1) |
| `MinterUSDCZap_v4` | `allowedStabilityPools` (slot 0), `__gap[50]` (slot 1) |
| `GenesisETHZap_v5` | `__gap[51]` (slot 0) |
| `GenesisUSDCZap_v5` | `__gap[50]` (slot 0) |

### MinterETHZap: slot collision example

| Slot | v3 (production) | v4 (branch) |
|------|-----------------|-------------|
| 0 | `referral` | `allowedStabilityPools` |
| 1 | `allowedStabilityPools` | `__gap[0]` |

Upgrading a live v3 proxy would map the old `referral` address into the `allowedStabilityPools` mapping seed (corrupt allowlist) and shift the mapping root.

### GenesisETHZap: slot collision example

| Slot | v4 (production) | v5 (branch) |
|------|-----------------|-------------|
| 0 | `referral` | `__gap[0]` |

Upgrading would orphan the stored referral and repurpose slot 0 for gap padding.

## Safe upgrade path (same major version only)

UUPS upgrades are safe **only** between implementations with **identical** contract-specific storage (e.g. v4 impl A → v4 impl B with matching layout). Use:

```bash
forge build
bash script/dump-zap-storage-layout.sh
forge inspect <Contract> storageLayout --json > layout-new.json
# diff against saved layout from current mainnet implementation
```

## Recommended deployment model for v4/v5

1. Deploy new implementation + new UUPS proxy per market.
2. Point frontends/indexers to new proxy addresses.
3. Retire or freeze old proxies after migration window.
4. Do **not** call `upgradeTo` on production v3/v4 proxies with v4/v5 implementation addresses.
