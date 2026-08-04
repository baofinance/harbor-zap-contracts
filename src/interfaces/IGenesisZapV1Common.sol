// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// solhint-disable func-name-mixedcase

/// @title IGenesisZapV1Common
/// @notice ABI shared by `GenesisETHZap_v1` and `GenesisUSDCZap_v1`.
/// @dev Pair with `IGenesisZapV1Native` (ETH: `zapNativeAsset` payable) or `IGenesisZapV1BaseErc20` (USDC:
///      `zapBaseAsset` / `zapBaseAssetWithPermit`) for zap entrypoints.
///
/// ## Preview semantics (high level)
/// - **ETH zap (`GenesisETHZap_v1`)**: `previewWrappedCollateralFromBase` / `FromCollateral` use Lido + wstETH view
///   math; `balanceOf*` / `totalValueBaseAsset` use on-chain conversion views where supported.
/// - **USDC zap (`GenesisUSDCZap_v1`)**: `previewWrappedCollateralFromBase` uses **$1 USDC ≈ 1 fxUSD** (6→18 dec
///   scaling) then **fxSAVE `IERC4626.convertToShares`** — a model of vault math, **not** a simulation of the
///   fxUSD diamond `convert` path. `FromCollateral` uses `convertToShares` on the same nominal fxUSD amount;
///   fxSAVE’s accounting asset may differ from fxUSD (see NatSpec on `FxUSDZapBase_v1`). Always use slippage
///   (`minWrappedCollateralOut`) on real zaps. `balanceOfBaseAsset`, `balanceOfCollateral`, `totalValueBaseAsset`
///   revert `PreviewNotSupported` on the USDC zap (no oracle parity with the ETH zap).
interface IGenesisZapV1Common {
    function GENESIS() external view returns (address);
    function BASE_ASSET() external view returns (address);
    function COLLATERAL_ASSET() external view returns (address);
    function WRAPPED_COLLATERAL_ASSET() external view returns (address);

    /// @notice fxUSD-style zaps: fxUSD diamond (depositToFxSave). ETH zaps: `address(0)`.
    function COLLATERAL_MANAGER() external view returns (address);

    /// @notice fxUSD-style zaps: swap router passed into diamond. ETH zaps: `address(0)`.
    function SWAP_ROUTER() external view returns (address);

    /// @notice fxUSD-style zaps: first `convert` selector on diamond path. ETH zaps: `bytes4(0)`.
    function CONVERT_SELECTOR() external view returns (bytes4);

    function balanceOfBaseAsset(address user) external view returns (uint256);

    function balanceOfCollateral(address user) external view returns (uint256);

    function totalValueBaseAsset() external view returns (uint256);

    function previewWrappedCollateralFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 wrappedCollateralAmount);

    function previewWrappedCollateralFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 wrappedCollateralAmount);

    function previewSharesFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 sharesOut, uint256 wrappedCollateralAmount);

    function previewSharesFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 sharesOut, uint256 wrappedCollateralAmount);

    /// @notice Genesis uses 1:1 deposits: wrapped collateral amount equals shares minted
    function previewSharesFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 sharesOut);

    function zapName() external view returns (string memory);

    function rescueNativeAsset() external;

    function rescueToken(address token) external;

    receive() external payable;

    fallback() external payable;
}
