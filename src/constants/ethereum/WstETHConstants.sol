// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title WstETH Constants
/// @notice Constants used by ETH/wstETH zap contracts
library WstETHConstants {
    /// @notice stETH token address (mainnet)
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    /// @notice wstETH token address (mainnet)
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    /// @notice Default Lido referral address (Harbor's referral)
    address internal constant DEFAULT_REFERRAL = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
}
