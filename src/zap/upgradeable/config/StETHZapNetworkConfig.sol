// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WstETHConstants} from "@harbor/constants/ethereum/WstETHConstants.sol";
import {MegaETHWstETHConstants} from "@harbor/constants/megaeth/MegaETHWstETHConstants.sol";

/// @title stETH / wstETH zap network configuration
/// @notice Declarative config for zaps whose wrapped collateral is wstETH (native ETH + stETH paths).
library StETHZapNetworkConfig {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant MEGAETH_CHAIN_ID = 4326;

    struct Config {
        address defaultReferral;
        address baseAsset;
        address collateralAsset;
        address wrappedCollateralAsset;
        /// @dev ABI parity with fxUSD zaps: stETH path does not use a diamond (`address(0)`).
        address collateralManager;
        /// @dev ABI parity with fxUSD zaps: unused on stETH path (`address(0)`).
        address swapRouter;
        /// @dev ABI parity with fxUSD zaps: unused on stETH path (`bytes4(0)`).
        bytes4 convertSelector;
        bool supportsBaseAsset;
        bool supportsCollateralAsset;
    }

    function load(uint256 chainId) internal pure returns (Config memory cfg) {
        if (chainId == MAINNET_CHAIN_ID) {
            cfg.defaultReferral = WstETHConstants.DEFAULT_REFERRAL;
            cfg.baseAsset = address(0);
            cfg.collateralAsset = WstETHConstants.STETH;
            cfg.wrappedCollateralAsset = WstETHConstants.WSTETH;
            cfg.collateralManager = address(0);
            cfg.swapRouter = address(0);
            cfg.convertSelector = bytes4(0);
            cfg.supportsBaseAsset = true;
            cfg.supportsCollateralAsset = true;
            return cfg;
        }

        if (chainId == MEGAETH_CHAIN_ID) {
            cfg.defaultReferral = address(0);
            cfg.baseAsset = address(0);
            cfg.collateralAsset = address(0);
            cfg.wrappedCollateralAsset = MegaETHWstETHConstants.WSTETH;
            cfg.collateralManager = address(0);
            cfg.swapRouter = address(0);
            cfg.convertSelector = bytes4(0);
            cfg.supportsBaseAsset = false;
            cfg.supportsCollateralAsset = false;
            return cfg;
        }

        cfg.defaultReferral = address(0);
        cfg.baseAsset = address(0);
        cfg.collateralAsset = address(0);
        cfg.wrappedCollateralAsset = address(0);
        cfg.collateralManager = address(0);
        cfg.swapRouter = address(0);
        cfg.convertSelector = bytes4(0);
        cfg.supportsBaseAsset = false;
        cfg.supportsCollateralAsset = false;
    }
}
