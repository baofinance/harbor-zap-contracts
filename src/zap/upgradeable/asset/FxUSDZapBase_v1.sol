// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFxUSDDiamondV2} from "src/interfaces/IFxUSD.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title FxUSDZapBase_v1
/// @notice Internal helpers for fxUSD diamond → fxSAVE conversion paths (Genesis + Minter zaps).
abstract contract FxUSDZapBase_v1 {
    using SafeERC20 for IERC20;

    /// @dev `tokenIn` balance already in this contract; approves collateral manager (e.g. fxUSD diamond) then deposits to wrapped collateral.
    function _convertHeldTokenToWrappedCollateral(
        address collateralManager,
        address swapRouter,
        address wrappedCollateralAsset,
        bytes4 convertSelector,
        address tokenIn,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256 wrappedCollateralReceived) {
        IERC20 token = IERC20(tokenIn);
        _safeApprove(token, collateralManager, amountIn);

        bytes memory data = abi.encodeWithSelector(convertSelector, tokenIn, amountIn, minOut, bytes(""));

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: tokenIn,
            amount: amountIn,
            target: swapRouter,
            data: data,
            minOut: minOut,
            signature: ""
        });

        uint256 balanceBefore = IERC20(wrappedCollateralAsset).balanceOf(address(this));
        IFxUSDDiamondV2(collateralManager).depositToFxSave{value: 0}(params, tokenIn, 0, address(this));
        wrappedCollateralReceived = IERC20(wrappedCollateralAsset).balanceOf(address(this)) - balanceBefore;

        if (wrappedCollateralReceived == 0) revert IZapErrors.NoWrappedCollateralReceived();
        if (wrappedCollateralReceived < minOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(wrappedCollateralReceived, minOut);
        }
    }

    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current == amount) return;
        if (current > 0) {
            token.safeDecreaseAllowance(spender, current);
        }
        if (amount > 0) {
            token.safeIncreaseAllowance(spender, amount);
        }
    }

    /// @notice fxSAVE shares for an 18‑decimal **vault asset** amount using ERC4626 `convertToShares`.
    /// @dev fxSAVE’s `asset()` is the fxSAVE receipt token’s accounting asset (e.g. fxSP), not necessarily the
    ///      zap’s `COLLATERAL_ASSET` (fxUSD). Collateral previews pass the same nominal 18‑dec amount as the live
    ///      zap uses for fxUSD; this matches `convertToShares` when those units align with what the vault expects.
    ///      If the protocol changes asset accounting, revisit this helper or use off‑chain simulation of the diamond.
    function _previewFxSaveSharesFromFxUsd(address fxSave, address, uint256 fxUsdAssets) internal view returns (uint256 shares) {
        if (fxUsdAssets == 0) return 0;
        shares = IERC4626(fxSave).convertToShares(fxUsdAssets);
    }

    /// @notice fxSAVE shares for USDC (6 decimals) using `convertToShares` after scaling to 18 decimals.
    /// @dev Assumes **$1 USDC ≈ 1 fxUSD** for preview math only; the live diamond `convert` path can differ (use `minWrappedCollateralOut`).
    function _previewFxSaveSharesFromUsdcAssumedPeg(address fxSave, address fxUsd, uint256 usdcAmount)
        internal
        view
        returns (uint256 shares)
    {
        if (usdcAmount == 0) return 0;
        return _previewFxSaveSharesFromFxUsd(fxSave, fxUsd, usdcAmount * 1e12);
    }
}
