// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Interface for the diamond contract's depositToFxSave function
interface IFxUSDDiamondV2 {
    struct ConvertInParams {
        address tokenIn;
        uint256 amount;
        address target;
        bytes data;
        uint256 minOut;
        bytes signature;
    }

    function depositToFxSave(
        ConvertInParams memory params,
        address tokenOut,
        uint256 minShares,
        address receiver
    ) external payable;
}
