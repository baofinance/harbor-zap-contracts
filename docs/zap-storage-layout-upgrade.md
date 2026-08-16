# Zap storage layout: production v3/v4 vs branch v1 (new family)

Use this document before any UUPS implementation swap. Run `script/dump-zap-storage-layout.sh` after `forge build` to print the current branch layouts.

**Verdict: do not upgrade production v3 Minter or v4 Genesis proxies in-place to branch v1 implementations.** Deploy new proxies per market. Branch contracts are versioned `_v1` because they are a new implementation family (not storage-compatible successors).

## Why in-place upgrade is unsafe

1. **Removed `referral` storage** on ETH zaps — production v3 Minter and v4 Genesis stored `address referral` at root slot 0. Branch v1 makes referral an **immutable** from `StETHZapNetworkConfig` (no root slot).
2. **Allowlist moved to ERC-7201** — production Minter zaps kept `allowedStabilityPools` at a root slot. Branch v1 stores it only under `harborzap.storage.Minter*Zap_v1` (no root slots). An in-place upgrade would leave old root-slot data orphaned and the namespaced mapping empty.
3. **No `__gap` on branch v1 concrete zaps** — Genesis v1 is immutables-only; Minter v1 contract-specific state is namespaced only.
4. **Constants → constructor immutables** — network addresses moved to constructor-set immutables (new implementation bytecode; confirms a new family).
5. **Inheritance change** — shared bases (`MinterZapBase_v1`, `GenesisZapBase_v1`, asset bases) alter the compiled contract versus monolithic v3/v4.

`HarborOwnable` / prior `BaoOwnable` use ERC-7201 namespaced owner storage. The incompatibility is in **contract-specific state** below.

## Production baseline (git `9f31d46^`)

| Contract | Contract-specific storage | Notes |
|----------|-------------------------|-------|
| `MinterETHZap_v3` | `referral` (slot 0), `allowedStabilityPools` (slot 1) | No `__gap` |
| `MinterUSDCZap_v3` | `allowedStabilityPools` (slot 0) | No `__gap` |
| `GenesisETHZap_v4` | `referral` (slot 0) | No `__gap` |
| `GenesisUSDCZap_v4` | *(none beyond inherited owner)* | No `__gap` |

## Branch v1 (`forge inspect` output)

| Contract | Contract-specific storage |
|----------|---------------------------|
| `MinterETHZap_v1` | ERC-7201 `harborzap.storage.MinterETHZap_v1` (`allowedStabilityPools`) — no root slots |
| `MinterUSDCZap_v1` | ERC-7201 `harborzap.storage.MinterUSDCZap_v1` (`allowedStabilityPools`) — no root slots |
| `GenesisETHZap_v1` | *(none — immutables only)* |
| `GenesisUSDCZap_v1` | *(none — immutables only)* |

### MinterETHZap: why in-place upgrade fails

| Location | v3 (production) | v1 (branch) |
|----------|-----------------|-------------|
| Root slot 0 | `referral` | *(unused / empty)* |
| Root slot 1 | `allowedStabilityPools` | *(unused / empty)* |
| ERC-7201 `harborzap.storage.MinterETHZap_v1` | *(absent)* | `allowedStabilityPools` |

Upgrading a live v3 proxy to v1 would **orphan** the old root-slot `referral` and allowlist. The namespaced allowlist reads as empty (all pools denied) until reconfigured. Old root values are not mapped into the ERC-7201 namespace.

### GenesisETHZap: why in-place upgrade fails

| Location | v4 (production) | v1 (branch) |
|----------|-----------------|-------------|
| Root slot 0 | `referral` | *(unused / empty — referral is immutable)* |

Upgrading would orphan the stored referral; the new implementation ignores root slot 0 and uses the immutable from config instead.

## Safe upgrade path (same major version only)

UUPS upgrades are safe **only** between implementations with **identical** contract-specific storage (e.g. branch v1 impl A → v1 impl B with matching layout). Use:

```bash
forge build
bash script/dump-zap-storage-layout.sh
forge inspect <Contract> storageLayout --json > layout-new.json
# diff against saved layout from current mainnet implementation
```

## Recommended deployment model for branch v1

1. Deploy new implementation + new UUPS proxy per market.
2. Point frontends/indexers to new proxy addresses.
3. Retire or freeze old proxies after migration window.
4. Do **not** call `upgradeTo` on production v3/v4 proxies with branch `_v1` implementation addresses.
