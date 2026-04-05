// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IGenesisZapV5Common
/// @notice ABI shared by `GenesisETHZap_v5` and `GenesisUSDCZap_v5`.
/// @dev Pair with `IGenesisZapV5BaseNative` (ETH) or `IGenesisZapV5BaseErc20` (USDC) for zap entrypoints.
interface IGenesisZapV5Common {
    function GENESIS() external view returns (address);
    function BASE_ASSET() external view returns (address);
    function COLLATERAL_ASSET() external view returns (address);
    function WRAPPED_COLLATERAL_ASSET() external view returns (address);

    function balanceOfBaseAsset(address user) external view returns (uint256);

    function balanceOfCollateral(address user) external view returns (uint256);

    function totalValueBaseAsset() external view returns (uint256);

    function previewWrappedCollateralFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount);

    function previewWrappedCollateralFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount);

    function previewSharesFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount);

    function previewSharesFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount);

    /// @notice Genesis uses 1:1 deposits: wrapped collateral amount equals shares minted
    function previewSharesFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        view
        returns (uint256 sharesOut);

    function zapName() external view returns (string memory);

    function rescueNativeAsset() external;

    function rescueToken(address token) external;

    receive() external payable;

    fallback() external payable;
}
