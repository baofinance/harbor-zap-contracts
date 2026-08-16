// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// solhint-disable func-name-mixedcase

/// @title IMinterZapV1Common
/// @notice ABI shared by `MinterETHZap_v1` and `MinterUSDCZap_v1` (collateral, wrapped, previews, owner helpers).
/// @dev Pair with `IMinterZapV1BaseNative` (ETH: `zapNativeAssetTo*` payable) or `IMinterZapV1BaseErc20` (USDC:
///      `zapBaseAssetTo*`) for the full surface.
interface IMinterZapV1Common {
    // ----- Constants / config (auto-getters match `public constant` / `immutable`) -----
    function MINTER() external view returns (address);
    function BASE_ASSET() external view returns (address);
    function COLLATERAL_ASSET() external view returns (address);
    function WRAPPED_COLLATERAL_ASSET() external view returns (address);

    /// @notice USDC zaps: fxUSD diamond. ETH zaps: `address(0)`.
    function COLLATERAL_MANAGER() external view returns (address);

    /// @notice USDC zaps: swap router for diamond. ETH zaps: `address(0)`.
    function SWAP_ROUTER() external view returns (address);

    /// @notice USDC zaps: first `convert` selector. ETH zaps: `bytes4(0)`.
    function CONVERT_SELECTOR() external view returns (bytes4);

    function allowedStabilityPools(address stabilityPool) external view returns (bool);

    // ----- Collateral zaps -----
    function zapCollateralToPegged(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) external returns (uint256 peggedOut);

    function zapCollateralToLeveraged(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) external returns (uint256 leveragedOut);

    function zapCollateralToStabilityPool(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external returns (uint256 peggedOut, uint256 deposited);

    // ----- Wrapped collateral → StabilityPool -----
    function zapWrappedCollateralToStabilityPool(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external returns (uint256 peggedOut, uint256 deposited);

    // ----- Permit: collateral & wrapped (same signatures on both zaps) -----
    function zapCollateralToPeggedWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 peggedOut);

    function zapCollateralToLeveragedWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 leveragedOut);

    function zapCollateralToStabilityPoolWithPermit(
        uint256 collateralAmount,
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

    function zapWrappedCollateralToStabilityPoolWithPermit(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 peggedOut, uint256 deposited);

    // ----- Previews (same selectors on ETH and USDC zaps; USDC leg: ERC4626 `convertToShares` model + peg assumption for USDC→fxUSD, then minter dry-runs for mint previews — not a diamond simulation; use slippage on-chain) -----
    function previewWrappedCollateralFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 wrappedCollateralAmount);

    function previewWrappedCollateralFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 wrappedCollateralAmount);

    function previewPeggedFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount);

    function previewLeveragedFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 leveragedOut, uint256 wrappedCollateralAmount);

    function previewPeggedFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount);

    function previewLeveragedFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 leveragedOut, uint256 wrappedCollateralAmount);

    function previewStabilityPoolFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount);

    function previewStabilityPoolFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount);

    function previewPeggedFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 peggedOut);

    function previewLeveragedFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 leveragedOut);

    function previewStabilityPoolFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 peggedOut);

    function zapName() external view returns (string memory);

    // ----- Owner -----
    function setStabilityPoolAllowed(address stabilityPool, bool allowed) external;
    function rescueNativeAsset() external;
    function rescueToken(address token) external;

    receive() external payable;
    fallback() external payable;
}
