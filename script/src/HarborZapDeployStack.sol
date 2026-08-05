// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {GenesisETHZap_v1} from "@harborzap/zap/upgradeable/GenesisETHZap_v1.sol";
import {GenesisUSDCZap_v1} from "@harborzap/zap/upgradeable/GenesisUSDCZap_v1.sol";
import {MinterETHZap_v1} from "@harborzap/zap/upgradeable/MinterETHZap_v1.sol";
import {MinterUSDCZap_v1} from "@harborzap/zap/upgradeable/MinterUSDCZap_v1.sol";

import {HarborZapFactoryDeployer} from "@harborzap-script/src/HarborZapFactoryDeployer.sol";

/// @title HarborZapDeployStack
/// @notice Idempotent CREATE3 deploy helpers for the four production zap proxies.
/// @dev Existence checks run before `new <Zap>_v1(...)` so re-runs do not orphan implementations.
abstract contract HarborZapDeployStack is HarborZapFactoryDeployer {
    function deployGenesisEthZap(
        DeploymentTypes.State memory stateData,
        address genesis,
        address deployer
    ) internal returns (address proxy) {
        if (_skipIfProxyExists(stateData, "genesisEthZap")) {
            return _predictAddress("genesisEthZap");
        }
        return
            _deployZap({
                stateData: stateData,
                proxyId: "genesisEthZap",
                source: "@harborzap/zap/upgradeable/GenesisETHZap_v1.sol",
                contractName: "GenesisETHZap_v1",
                impl: address(new GenesisETHZap_v1(genesis)),
                initData: abi.encodeCall(GenesisETHZap_v1.initialize, (deployer, owner()))
            });
    }

    function deployGenesisUsdcZap(
        DeploymentTypes.State memory stateData,
        address genesis,
        address deployer
    ) internal returns (address proxy) {
        if (_skipIfProxyExists(stateData, "genesisUsdcZap")) {
            return _predictAddress("genesisUsdcZap");
        }
        return
            _deployZap({
                stateData: stateData,
                proxyId: "genesisUsdcZap",
                source: "@harborzap/zap/upgradeable/GenesisUSDCZap_v1.sol",
                contractName: "GenesisUSDCZap_v1",
                impl: address(new GenesisUSDCZap_v1(genesis)),
                initData: abi.encodeCall(GenesisUSDCZap_v1.initialize, (deployer, owner()))
            });
    }

    function deployMinterEthZap(
        DeploymentTypes.State memory stateData,
        address minter,
        address deployer
    ) internal returns (address proxy) {
        if (_skipIfProxyExists(stateData, "minterEthZap")) {
            return _predictAddress("minterEthZap");
        }
        return
            _deployZap({
                stateData: stateData,
                proxyId: "minterEthZap",
                source: "@harborzap/zap/upgradeable/MinterETHZap_v1.sol",
                contractName: "MinterETHZap_v1",
                impl: address(new MinterETHZap_v1(minter)),
                initData: abi.encodeCall(MinterETHZap_v1.initialize, (deployer, owner()))
            });
    }

    function deployMinterUsdcZap(
        DeploymentTypes.State memory stateData,
        address minter,
        address deployer
    ) internal returns (address proxy) {
        if (_skipIfProxyExists(stateData, "minterUsdcZap")) {
            return _predictAddress("minterUsdcZap");
        }
        return
            _deployZap({
                stateData: stateData,
                proxyId: "minterUsdcZap",
                source: "@harborzap/zap/upgradeable/MinterUSDCZap_v1.sol",
                contractName: "MinterUSDCZap_v1",
                impl: address(new MinterUSDCZap_v1(minter)),
                initData: abi.encodeCall(MinterUSDCZap_v1.initialize, (deployer, owner()))
            });
    }

    function _skipIfProxyExists(
        DeploymentTypes.State memory stateData,
        string memory proxyId
    ) private returns (bool skip) {
        if (!DeploymentState.hasProxy(stateData, proxyId)) {
            return false;
        }
        console.log(string.concat("    > ", proxyId));
        console.log("        already in state -> %s (skipping)", _predictAddress(proxyId));
        return true;
    }

    function _deployZap(
        DeploymentTypes.State memory stateData,
        string memory proxyId,
        string memory source,
        string memory contractName,
        address impl,
        bytes memory initData
    ) private returns (address proxy) {
        console.log(string.concat("    > ", proxyId));
        // Dual-check: callers already skip when recorded; keep for safety if invoked directly.
        if (DeploymentState.hasProxy(stateData, proxyId)) {
            proxy = _predictAddress(proxyId);
            console.log("        already in state -> %s (skipping)", proxy);
            return proxy;
        }

        console.log("        Impl: %s", impl);
        _recordImplementation(stateData, proxyId, source, contractName, impl);
        proxy = _deployProxyAndRecord(stateData, proxyId, impl, initData);
        console.log("        Proxy: %s", proxy);
    }
}
