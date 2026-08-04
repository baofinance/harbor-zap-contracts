// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {GenesisETHZap_v5} from "@harborzap/zap/upgradeable/GenesisETHZap_v5.sol";
import {GenesisUSDCZap_v5} from "@harborzap/zap/upgradeable/GenesisUSDCZap_v5.sol";
import {MinterETHZap_v4} from "@harborzap/zap/upgradeable/MinterETHZap_v4.sol";
import {MinterUSDCZap_v4} from "@harborzap/zap/upgradeable/MinterUSDCZap_v4.sol";

import {HarborZapFactoryDeployer} from "@harborzap-script/src/HarborZapFactoryDeployer.sol";

/// @title HarborZapDeployStack
/// @notice Idempotent CREATE3 deploy helpers for the four production zap proxies.
abstract contract HarborZapDeployStack is HarborZapFactoryDeployer {
    function deployGenesisEthZap(DeploymentTypes.State memory stateData, address genesis, address deployer)
        internal
        returns (address proxy)
    {
        return _deployZap({
            stateData: stateData,
            proxyId: "genesisEthZap",
            source: "@harborzap/zap/upgradeable/GenesisETHZap_v5.sol",
            contractName: "GenesisETHZap_v5",
            impl: address(new GenesisETHZap_v5(genesis)),
            initData: abi.encodeCall(GenesisETHZap_v5.initialize, (deployer, owner()))
        });
    }

    function deployGenesisUsdcZap(DeploymentTypes.State memory stateData, address genesis, address deployer)
        internal
        returns (address proxy)
    {
        return _deployZap({
            stateData: stateData,
            proxyId: "genesisUsdcZap",
            source: "@harborzap/zap/upgradeable/GenesisUSDCZap_v5.sol",
            contractName: "GenesisUSDCZap_v5",
            impl: address(new GenesisUSDCZap_v5(genesis)),
            initData: abi.encodeCall(GenesisUSDCZap_v5.initialize, (deployer, owner()))
        });
    }

    function deployMinterEthZap(DeploymentTypes.State memory stateData, address minter, address deployer)
        internal
        returns (address proxy)
    {
        return _deployZap({
            stateData: stateData,
            proxyId: "minterEthZap",
            source: "@harborzap/zap/upgradeable/MinterETHZap_v4.sol",
            contractName: "MinterETHZap_v4",
            impl: address(new MinterETHZap_v4(minter)),
            initData: abi.encodeCall(MinterETHZap_v4.initialize, (deployer, owner()))
        });
    }

    function deployMinterUsdcZap(DeploymentTypes.State memory stateData, address minter, address deployer)
        internal
        returns (address proxy)
    {
        return _deployZap({
            stateData: stateData,
            proxyId: "minterUsdcZap",
            source: "@harborzap/zap/upgradeable/MinterUSDCZap_v4.sol",
            contractName: "MinterUSDCZap_v4",
            impl: address(new MinterUSDCZap_v4(minter)),
            initData: abi.encodeCall(MinterUSDCZap_v4.initialize, (deployer, owner()))
        });
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
