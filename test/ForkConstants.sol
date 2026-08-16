// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Shared mainnet fork pin for zap integration / unit-on-fork suites.
/// @dev Near tip as of 2026-08-06 (~block 25_698_728): haUSD Genesis `0x40ff…05fD` still open.
///      Bump deliberately when a newer protocol state is required.
library ForkConstants {
    uint256 internal constant MAINNET_FORK_BLOCK = 25_698_000;
}
