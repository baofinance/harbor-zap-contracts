// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MegaETH wstETH token address
/// @notice Same value as harbor `script/config/chains/ConfigChain_megaeth.sol` (`wstETH()`).
/// @dev Mainnet zaps use `src/constants/ethereum/WstETHConstants.sol`. For MegaETH-native bytecode,
///      point ETH zaps at this library instead (and confirm any bridged `stETH` address if `submit`-based flows apply).
library MegaETHWstETHConstants {
    address internal constant WSTETH = 0x601aC63637933D88285A025C685AC4e9a92a98dA;
}
