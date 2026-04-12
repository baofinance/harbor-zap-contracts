// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {WstETHConstants} from "src/constants/ethereum/WstETHConstants.sol";
import {MegaETHWstETHConstants} from "src/constants/megaeth/MegaETHWstETHConstants.sol";

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
        bool supportsBaseAsset;
        bool supportsCollateralAsset;
    }

    function load(uint256 chainId) internal pure returns (Config memory cfg) {
        if (chainId == MAINNET_CHAIN_ID) {
            cfg.defaultReferral = WstETHConstants.DEFAULT_REFERRAL;
            cfg.baseAsset = address(0);
            cfg.collateralAsset = WstETHConstants.STETH;
            cfg.wrappedCollateralAsset = WstETHConstants.WSTETH;
            cfg.supportsBaseAsset = true;
            cfg.supportsCollateralAsset = true;
            return cfg;
        }

        if (chainId == MEGAETH_CHAIN_ID) {
            cfg.defaultReferral = address(0);
            cfg.baseAsset = address(0);
            cfg.collateralAsset = address(0);
            cfg.wrappedCollateralAsset = MegaETHWstETHConstants.WSTETH;
            cfg.supportsBaseAsset = false;
            cfg.supportsCollateralAsset = false;
            return cfg;
        }

        cfg.defaultReferral = address(0);
        cfg.baseAsset = address(0);
        cfg.collateralAsset = address(0);
        cfg.wrappedCollateralAsset = address(0);
        cfg.supportsBaseAsset = false;
        cfg.supportsCollateralAsset = false;
    }
}
