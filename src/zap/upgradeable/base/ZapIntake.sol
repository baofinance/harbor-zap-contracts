// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
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
    /// @dev Callers always pass `_msgSender()` / `msg.sender` as `from` (user-initiated pull).
    function pullExact(IERC20 token, address from, uint256 amount) internal returns (uint256 received) {
        uint256 beforeBal = token.balanceOf(address(this));
        // slither-disable-next-line arbitrary-send-erc20 — `from` is the zap caller (msg.sender / _msgSender)
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
        // slither-disable-next-line arbitrary-send-erc20 — `from` is the zap caller (msg.sender / _msgSender)
        token.safeTransferFrom(from, address(this), amount);
        received = token.balanceOf(address(this)) - beforeBal;
        // slither-disable-next-line incorrect-equality — zero / over-delivery are hard failures for FoT / rounding
        if (received == 0 || received > amount) {
            revert IZapErrors.UnexpectedAmountIn(amount, received);
        }
    }

    /// @notice Refund any balance of `token` above `baseline` to `to` (unspent input after a convert leg).
    function refundLeftoverAbove(IERC20 token, uint256 baseline, address to) internal {
        uint256 bal = token.balanceOf(address(this));
        if (bal > baseline) {
            token.safeTransfer(to, bal - baseline);
        }
    }

    /// @notice Consume an ERC-2612 permit from `owner` to this contract, tolerating front-running.
    /// @dev Permit signatures are public in the mempool; anyone can submit `token.permit` first, consuming
    ///      the nonce so a bare `permit` call here reverts and the whole zap is griefed for free. Per
    ///      OpenZeppelin's ERC-2612 guidance the failure is swallowed: if the allowance was in fact granted
    ///      (front-run with the same signature) the zap proceeds normally, and if it was not, the subsequent
    ///      `transferFrom` pull reverts with the token's own allowance error.
    function tryPermit(
        IERC20Permit token,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        try token.permit(owner, address(this), amount, deadline, v, r, s) {
            return;
        } catch {} // solhint-disable-line no-empty-blocks
    }
}
