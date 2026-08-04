// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IGenesisZapV1Native
/// @notice Native-ETH Genesis zaps (`GenesisETHZap_v1`).
/// @dev `zapNativeAsset` is the only payable “base” entrypoint on this rail. On success it emits `ZappedBaseAsset`
///      (declared on `GenesisZapBase_v1`) so topics match `GenesisUSDCZap_v1` / `zapBaseAsset`—there is **no**
///      `zapBaseAsset` function on the ETH zap; frontends must branch on contract type.
interface IGenesisZapV1Native {
    /// @notice Lido referral address passed to `submit` (fixed per implementation from `StETHZapNetworkConfig`)
    function referral() external view returns (address);

    /// @notice Zap native base asset (ETH) → collateral → wrapped collateral → Genesis
    function zapNativeAsset(
        address receiver,
        uint256 minWrappedCollateralOut,
        uint256 minBaseAssetEquivalentOut
    ) external payable returns (uint256 sharesOut);

    function zapCollateral(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) external returns (uint256 sharesOut);

    function zapCollateralWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 sharesOut);
}
