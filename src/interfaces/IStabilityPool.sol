// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Interface for StabilityPool deposit function
interface IStabilityPool {
    function deposit(uint256 assetAmount, address receiver, uint256 minAmount)
        external
        returns (uint256 assetsDeposited);
    function ASSET_TOKEN() external view returns (address);
}
