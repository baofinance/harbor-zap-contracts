// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMinterZapV4BaseNative
/// @notice Native-base-asset (ETH) entrypoints for `MinterETHZap_v4` via `msg.value`.
/// @dev Implement only on the ETH zap; USDC uses `IMinterZapV4BaseErc20` instead.
interface IMinterZapV4BaseNative {
    /// @notice Lido referral address passed to `submit` (fixed per implementation from `StETHZapNetworkConfig`)
    function referral() external view returns (address);

    /// @param minWrappedCollateralOut Minimum wstETH (or zap wrapped token) from ETH→wrap leg; 0 skips check
    function zapNativeAssetToPegged(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) external payable returns (uint256 peggedOut);

    function zapNativeAssetToLeveraged(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) external payable returns (uint256 leveragedOut);

    function zapNativeAssetToStabilityPool(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external payable returns (uint256 peggedOut, uint256 deposited);
}
