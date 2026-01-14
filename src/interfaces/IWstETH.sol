// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for wstETH wrap function
interface IWstETHWrapV2 {
    function wrap(uint256 stEthAmount) external returns (uint256);
}

/// @notice Interface for wstETH view functions (extends IERC20)
interface IWstETH is IERC20 {
    // forge-lint: disable-next-line(mixed-case-function)
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function stETH() external view returns (address);
}

/// @notice Interface for wstETH view functions (view-only, no IERC20)
interface IWstETHView {
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
}
