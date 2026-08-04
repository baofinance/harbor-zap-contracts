// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {HarborZapDeployStack} from "@harborzap-script/src/HarborZapDeployStack.sol";

/// @notice State-driven CREATE3 deploy of Harbor zap proxies for one market.
/// @dev Env:
///        MARKET          required market key (e.g. ETH, BTC, GOLD) — namespaces salt + state file
///        GENESIS_ETH     optional Genesis address for GenesisETHZap_v1 (skip if unset/zero)
///        GENESIS_USDC    optional Genesis address for GenesisUSDCZap_v1
///        MINTER_ETH      optional Minter address for MinterETHZap_v1
///        MINTER_USDC     optional Minter address for MinterUSDCZap_v1
///
/// Usage:
///   MARKET=GOLD GENESIS_USDC=0x... forge script script/Deploy_Zaps.s.sol:Deploy_Zaps \
///     --rpc-url mainnet --broadcast --slow --sender <deployer>
contract Deploy_Zaps is HarborZapDeployStack, Script {
    function run() external {
        string memory market = vm.envString("MARKET");
        require(bytes(market).length > 0, "MARKET required");
        _setMarketKey(market);

        address genesisEth = vm.envOr("GENESIS_ETH", address(0));
        address genesisUsdc = vm.envOr("GENESIS_USDC", address(0));
        address minterEth = vm.envOr("MINTER_ETH", address(0));
        address minterUsdc = vm.envOr("MINTER_USDC", address(0));
        require(
            genesisEth != address(0) ||
                genesisUsdc != address(0) ||
                minterEth != address(0) ||
                minterUsdc != address(0),
            "set at least one of GENESIS_ETH / GENESIS_USDC / MINTER_ETH / MINTER_USDC"
        );

        DeploymentTypes.State memory state = _loadState();

        console.log("=== Harbor Zap deploy (salted / CREATE3) ===");
        console.log("  market: %s", market);
        console.log("  saltPrefix: %s", saltPrefix());
        console.log("  state: %s", _stateFileRead());

        vm.startBroadcast();
        (, address deployer, ) = vm.readCallers();

        if (genesisEth != address(0)) {
            deployGenesisEthZap(state, genesisEth, deployer);
        }
        if (genesisUsdc != address(0)) {
            deployGenesisUsdcZap(state, genesisUsdc, deployer);
        }
        if (minterEth != address(0)) {
            deployMinterEthZap(state, minterEth, deployer);
        }
        if (minterUsdc != address(0)) {
            deployMinterUsdcZap(state, minterUsdc, deployer);
        }

        _transferAllOwnerships();
        _saveState(state);
        vm.stopBroadcast();

        console.log("Done. Multisig should confirm ownership where still pending.");
    }
}
