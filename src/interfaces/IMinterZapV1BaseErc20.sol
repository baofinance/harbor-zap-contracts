// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMinterZapV1BaseErc20
/// @notice Base-asset entrypoints for `MinterUSDCZap_v1` (ERC-20 pulled from caller + optional permit).
/// @dev Implement only on the USDC zap; ETH uses `IMinterZapV1BaseNative` (`zapNativeAssetTo*`) instead.
interface IMinterZapV1BaseErc20 {
    function zapBaseAssetToPegged(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) external returns (uint256 peggedOut);

    function zapBaseAssetToLeveraged(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) external returns (uint256 leveragedOut);

    function zapBaseAssetToStabilityPool(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external returns (uint256 peggedOut, uint256 deposited);

    function zapBaseAssetToPeggedWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 peggedOut);

    function zapBaseAssetToLeveragedWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 leveragedOut);

    function zapBaseAssetToStabilityPoolWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 peggedOut, uint256 deposited);
}
