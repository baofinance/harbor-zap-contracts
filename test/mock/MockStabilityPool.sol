// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock StabilityPool for testing
contract MockStabilityPool {
    using SafeERC20 for IERC20;

    address public immutable ASSET_TOKEN;
    mapping(address => uint256) public deposits;

    constructor(address assetToken_) {
        ASSET_TOKEN = assetToken_;
    }

    function deposit(
        uint256 assetAmount,
        address receiver,
        uint256 minAmount
    ) external returns (uint256 assetsDeposited) {
        if (assetAmount < minAmount) revert("Slippage");
        IERC20(ASSET_TOKEN).safeTransferFrom(msg.sender, address(this), assetAmount);
        deposits[receiver] += assetAmount;
        assetsDeposited = assetAmount;
    }

    function balanceOf(address user) external view returns (uint256) {
        return deposits[user];
    }
}
