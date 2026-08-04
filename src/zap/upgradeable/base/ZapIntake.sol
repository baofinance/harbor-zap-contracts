// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";

/// @title ZapIntake
/// @notice Exact-pull + leftover-refund helpers matching harbor-swap executor envelope hardening.
/// @dev `pullExact` rejects fee-on-transfer / non-standard ERC20 pulls. `pullMeasured` allows share-based
///      tokens (e.g. stETH) that may deliver 1–2 wei less, but still rejects zero delivery and over-delivery.
///      `refundLeftoverAbove` returns any unspent input after a conversion leg so dust does not stick in the zap.
library ZapIntake {
    using SafeERC20 for IERC20;

    /// @notice Pull `amount` from `from` and require the zap's balance increases by exactly `amount`.
    function pullExact(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBal;
        if (received != amount) {
            revert IZapErrors.UnexpectedAmountIn(amount, received);
        }
    }

    /// @notice Pull up to `amount`, requiring a positive delivery that does not exceed `amount`.
    /// @dev Use for share-based tokens (stETH) where transfers can round down by 1–2 wei.
    function pullMeasured(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBal;
        if (received == 0 || received > amount) {
            revert IZapErrors.UnexpectedAmountIn(amount, received);
        }
    }

    /// @notice Refund any balance of `token` above `baseline` to `to` (unspent input after a convert leg).
    function refundLeftoverAbove(IERC20 token, uint256 baseline, address to) internal returns (uint256 leftover) {
        uint256 bal = token.balanceOf(address(this));
        if (bal > baseline) {
            leftover = bal - baseline;
            token.safeTransfer(to, leftover);
        }
    }
}
