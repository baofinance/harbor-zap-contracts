// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";

/// @notice Shared internal mint/deposit logic for minter zaps.
/// @dev This is a refactor helper to reduce drift across ETH/USDC minter zaps.
// solhint-disable-next-line contract-name-capwords
abstract contract MinterZapShared_v1 {
    using SafeERC20 for IERC20;

    function _minterAddress() internal view virtual returns (address);
    function _wrappedCollateralAssetAddress() internal view virtual returns (address);
    function _isStabilityPoolAllowed(address stabilityPool) internal view virtual returns (bool);

    function _sharedMintPeggedToken(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minPeggedOut
    ) internal returns (uint256 peggedOut) {
        address minter = _minterAddress();
        address wrappedCollateral = _wrappedCollateralAssetAddress();
        address peggedToken = IMinter(minter).PEGGED_TOKEN();

        uint256 peggedBalanceBefore = IERC20(peggedToken).balanceOf(receiver);
        IERC20(wrappedCollateral).forceApprove(minter, wrappedCollateralAmount);
        peggedOut = IMinter(minter).mintPeggedToken(wrappedCollateralAmount, receiver, minPeggedOut);

        uint256 peggedBalanceAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 received = peggedBalanceAfter - peggedBalanceBefore;
        // slither-disable-next-line incorrect-equality — enforce return matches delta and rejects zero mint
        if (received != peggedOut || peggedOut == 0) {
            revert IZapErrors.MintMismatchExpected(peggedOut, received);
        }
    }

    function _sharedMintLeveragedToken(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minLeveragedOut
    ) internal returns (uint256 leveragedOut) {
        address minter = _minterAddress();
        address wrappedCollateral = _wrappedCollateralAssetAddress();
        address leveragedToken = IMinter(minter).LEVERAGED_TOKEN();

        uint256 leveragedBalanceBefore = IERC20(leveragedToken).balanceOf(receiver);
        IERC20(wrappedCollateral).forceApprove(minter, wrappedCollateralAmount);
        leveragedOut = IMinter(minter).mintLeveragedToken(wrappedCollateralAmount, receiver, minLeveragedOut);

        uint256 leveragedBalanceAfter = IERC20(leveragedToken).balanceOf(receiver);
        uint256 received = leveragedBalanceAfter - leveragedBalanceBefore;
        // slither-disable-next-line incorrect-equality — enforce return matches delta and rejects zero mint
        if (received != leveragedOut || leveragedOut == 0) {
            revert IZapErrors.MintMismatchExpected(leveragedOut, received);
        }
    }

    function _sharedDepositToStabilityPool(
        address peggedToken,
        address stabilityPool,
        uint256 peggedAmount,
        address receiver,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 deposited) {
        if (!_isStabilityPoolAllowed(stabilityPool)) {
            revert IZapErrors.StabilityPoolNotAllowed();
        }

        address poolAssetToken = IStabilityPool(stabilityPool).ASSET_TOKEN();
        if (poolAssetToken != peggedToken) {
            revert IZapErrors.CollateralMismatch(peggedToken, poolAssetToken);
        }

        uint256 balanceBefore = IERC20(peggedToken).balanceOf(address(this));
        if (balanceBefore < peggedAmount) {
            revert IZapErrors.InsufficientBalance(balanceBefore, peggedAmount);
        }

        IERC20(peggedToken).forceApprove(stabilityPool, peggedAmount);
        deposited = IStabilityPool(stabilityPool).deposit(peggedAmount, receiver, minStabilityPoolOut);

        uint256 balanceAfter = IERC20(peggedToken).balanceOf(address(this));
        uint256 balanceDecrease = balanceBefore - balanceAfter;
        if (balanceDecrease != peggedAmount) revert IZapErrors.DepositFailed();
        if (deposited != peggedAmount) revert IZapErrors.DepositFailed();

        IERC20(peggedToken).forceApprove(stabilityPool, 0);
    }
}
