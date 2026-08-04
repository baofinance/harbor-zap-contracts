// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IGenesisZapV1BaseErc20
/// @notice ERC-20 base Genesis zaps (`GenesisUSDCZap_v1`).
interface IGenesisZapV1BaseErc20 {
    function zapBaseAsset(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) external returns (uint256 sharesOut);

    function zapCollateral(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) external returns (uint256 sharesOut);

    function zapBaseAssetWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
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
