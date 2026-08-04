// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {MinterZapShared_v1} from "@harborzap/zap/upgradeable/base/MinterZapShared_v1.sol";
import {ZapIntake} from "@harborzap/zap/upgradeable/base/ZapIntake.sol";

/// @title MinterZapBase_v1
/// @notice Storage-free template for minter zaps: shared zap pipeline + mint/stability helpers.
/// @dev Child contracts supply conversion, asset checks, and allowance resets.
abstract contract MinterZapBase_v1 is MinterZapShared_v1 {
    using SafeERC20 for IERC20;

    // --- Shared events (ETH and USDC minter zaps emit identical topics) ---

    event BaseAssetZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut
    );

    event BaseAssetZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 leveragedOut
    );

    event CollateralZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut
    );

    event CollateralZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 leveragedOut
    );

    event BaseAssetZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    event CollateralZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    event WrappedCollateralZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    function _convertToWrappedCollateral(address tokenIn, uint256 amountIn, uint256 minWrappedCollateralOut)
        internal
        virtual
        returns (uint256 wrappedCollateralAmount);

    function _requireSupportedAsset(address asset) internal view virtual;

    function _resetAllowances() internal virtual;

    function _zapToPegged(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 peggedOut) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        wrappedCollateralAmount = _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        peggedOut = _mintPeggedToken(wrappedCollateralAmount, receiver, minPeggedOut);
        _resetAllowances();
    }

    function _zapToLeveraged(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 leveragedOut) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        wrappedCollateralAmount = _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        leveragedOut = _mintLeveragedToken(wrappedCollateralAmount, receiver, minLeveragedOut);
        _resetAllowances();
    }

    function _zapToStabilityPoolFromToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 peggedOut, uint256 deposited) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();

        address wrapped = _wrappedCollateralAssetAddress();
        uint256 inputBaseline;
        if (tokenIn == wrapped) {
            inputBaseline = IERC20(wrapped).balanceOf(address(this));
            wrappedCollateralAmount = ZapIntake.pullExact(IERC20(wrapped), msg.sender, amountIn);
            if (wrappedCollateralAmount < minWrappedCollateralOut) {
                revert IZapErrors.SlippageTooHighWrappedCollateral(
                    wrappedCollateralAmount, minWrappedCollateralOut
                );
            }
        } else {
            wrappedCollateralAmount = _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        }

        address peggedToken = IMinter(_minterAddress()).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wrappedCollateralAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        if (tokenIn == wrapped) {
            // Refund any unspent wrapped collateral (should be zero on the happy path).
            ZapIntake.refundLeftoverAbove(IERC20(wrapped), inputBaseline, msg.sender);
        }
        _resetAllowances();
    }

    function _mintPeggedToken(uint256 wrappedCollateralAmount, address receiver, uint256 minPeggedOut)
        internal
        returns (uint256 peggedOut)
    {
        return _sharedMintPeggedToken(wrappedCollateralAmount, receiver, minPeggedOut);
    }

    function _mintLeveragedToken(uint256 wrappedCollateralAmount, address receiver, uint256 minLeveragedOut)
        internal
        returns (uint256 leveragedOut)
    {
        return _sharedMintLeveragedToken(wrappedCollateralAmount, receiver, minLeveragedOut);
    }

    function _depositToStabilityPool(
        address peggedToken,
        address stabilityPool,
        uint256 peggedAmount,
        address receiver,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 deposited) {
        return _sharedDepositToStabilityPool(
            peggedToken, stabilityPool, peggedAmount, receiver, minStabilityPoolOut
        );
    }
}
