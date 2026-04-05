// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMinterZapV4BaseNative
/// @notice Base-asset entrypoints for `MinterETHZap_v4` (native ETH via `msg.value`).
/// @dev Implement only on the ETH zap; USDC uses `IMinterZapV4BaseErc20` instead.
interface IMinterZapV4BaseNative {
    /// @notice Lido referral address used for ETH → stETH (may be zero = default)
    function referral() external view returns (address);

    function setReferral(address newReferral) external;

    function zapBaseAssetToPegged(address receiver, uint256 minPeggedOut) external payable returns (uint256 peggedOut);

    function zapBaseAssetToLeveraged(address receiver, uint256 minLeveragedOut)
        external
        payable
        returns (uint256 leveragedOut);

    function zapBaseAssetToStabilityPool(
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external payable returns (uint256 peggedOut, uint256 deposited);
}
