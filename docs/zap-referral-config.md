# Lido referral config verification (branch `_v1` ETH zaps)

Production **MinterETHZap_v3** and **GenesisETHZap_v4** used mutable `referral` storage with deploy-time override:

- Constructor: `referral_ == address(0)` → `DEFAULT_REFERRAL`
- `initialize(..., referral_)`: non-zero `referral_` overrides storage
- Owner: `setReferral(address)` for post-deploy updates

## Production deployment evidence

All sampled mainnet deployment JSONs pass `referral: "0x0000000000000000000000000000000000000000"` (constructor and init). That resolves to the Harbor default at runtime.

## Branch `_v1` behavior

[`StETHZapNetworkConfig`](../src/zap/upgradeable/config/StETHZapNetworkConfig.sol) sets on mainnet (`chainId == 1`):

```solidity
cfg.defaultReferral = WstETHConstants.DEFAULT_REFERRAL;
// 0x3dFc49e5112005179Da613BdE5973229082dAc35
```

`MinterETHZap_v1` and `GenesisETHZap_v1`:

- Store `DEFAULT_REFERRAL` as an immutable from config at implementation deploy
- Expose `referral()` view returning that immutable
- Pass `DEFAULT_REFERRAL` to Lido `submit` in conversion paths
- **No** `setReferral`, **no** init `referral_` arg

## Conclusion

**Verified:** Branch `_v1` mainnet referral matches production behavior for all known deployments (zero deploy arg → Harbor default `0x3dFc...c35`).

**Operational change:** If Lido referral must change, deploy a new implementation with updated `WstETHConstants.DEFAULT_REFERRAL` / `StETHZapNetworkConfig` — there is no on-chain hot-fix.

MegaETH config (`chainId == 4326`) sets `defaultReferral = address(0)` (no native ETH submit path on that chain).
