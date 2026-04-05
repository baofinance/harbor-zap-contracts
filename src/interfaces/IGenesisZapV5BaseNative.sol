// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IGenesisZapV5BaseNative
/// @notice Native-ETH Genesis zaps (`GenesisETHZap_v5`).
interface IGenesisZapV5BaseNative {
    function referral() external view returns (address);

    function setReferral(address newReferral) external;

    function zapBaseAsset(
        address receiver,
        uint256 minWrappedCollateralOut,
        uint256 minBaseAssetEquivalentOut
    ) external payable returns (uint256 sharesOut);

    function zapCollateral(uint256 collateralAmount, uint256 minWrappedCollateralOut, address receiver)
        external
        returns (uint256 sharesOut);

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
