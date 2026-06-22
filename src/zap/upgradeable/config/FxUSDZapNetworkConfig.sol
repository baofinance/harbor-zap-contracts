// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FxSAVEConstants} from "@harbor/constants/ethereum/FxSAVEConstants.sol";

/// @title fxUSD / fxSAVE zap network configuration
/// @notice Declarative config for zaps whose wrapped collateral is fxSAVE (USDC + fxUSD paths).
library FxUSDZapNetworkConfig {
    uint256 internal constant MAINNET_CHAIN_ID = 1;

    struct Config {
        address usdc;
        address fxusd;
        address fxsave;
        address collateralManager;
        address swapRouter;
        bytes4 convertSelector;
    }

    /// @dev Returns zeroed `Config` for unsupported chains (fail-closed in constructors).
    function load(uint256 chainId) internal pure returns (Config memory cfg) {
        if (chainId == MAINNET_CHAIN_ID) {
            cfg.usdc = FxSAVEConstants.USDC;
            cfg.fxusd = FxSAVEConstants.FXUSD;
            cfg.fxsave = FxSAVEConstants.FXSAVE;
            cfg.collateralManager = FxSAVEConstants.FXUSD_DIAMOND;
            cfg.swapRouter = FxSAVEConstants.FXUSD_SWAP_ROUTER;
            cfg.convertSelector = FxSAVEConstants.CONVERT_SELECTOR;
        }
    }
}
