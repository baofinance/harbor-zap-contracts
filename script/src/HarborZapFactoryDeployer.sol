// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {FactoryDeployer, WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";

/// @title HarborZapFactoryDeployer
/// @notice Harbor Zap base for BaoFactory CREATE3 / state-driven deploys (mirrors harbor-tide).
abstract contract HarborZapFactoryDeployer is FactoryDeployer {
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Harbor multisig — final owner (same address on every chain).
    address internal constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    /// @notice Salt namespace root for Harbor Zap deployments.
    string internal constant SALT_PREFIX_ROOT = "harbor_zap_v1";

    string private _marketKey;

    /// @inheritdoc FactoryDeployer
    function owner() public pure override returns (address) {
        return HARBOR_MULTISIG;
    }

    /// @inheritdoc FactoryDeployer
    function treasury() public pure override returns (address) {
        return HARBOR_MULTISIG;
    }

    /// @notice Full salt prefix: `harbor_zap_v1` or `harbor_zap_v1_<MARKET>`.
    function saltPrefix() public view override returns (string memory) {
        if (bytes(_marketKey).length == 0) {
            return SALT_PREFIX_ROOT;
        }
        return string.concat(SALT_PREFIX_ROOT, "_", _marketKey);
    }

    function getWellKnownAddresses() public view virtual override returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](2);
        addrs[0] = WellKnownAddress({addr: HARBOR_MULTISIG, label: "harbor_multisig"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
    }

    function _setMarketKey(string memory marketKey) internal {
        _marketKey = marketKey;
    }

    function _market() internal view returns (string memory) {
        return _marketKey;
    }

    function _defaultStatePath() internal view returns (string memory) {
        if (bytes(_marketKey).length == 0) {
            return string.concat("deployments/state-", _vm.toString(block.chainid), ".json");
        }
        return string.concat("deployments/state-", _vm.toString(block.chainid), "-", _marketKey, ".json");
    }

    function _stateFileRead() internal view override returns (string memory) {
        return _vm.envOr("DEPLOY_STATE_FILE_READ", _defaultStatePath());
    }

    function _stateFileWrite() internal view override returns (string memory) {
        return _vm.envOr("DEPLOY_STATE_FILE_WRITE", _defaultStatePath());
    }

    function _saveState(DeploymentTypes.State memory stateData) internal override {
        if (!_shouldPersistState()) return;
        _vm.createDir("deployments", true);
        _vm.writeFile(_stateFileWrite(), JsonSerializer.renderState(stateData));
    }

    function _loadState() internal view returns (DeploymentTypes.State memory stateData) {
        stateData = DeploymentState.load(_stateFileRead());
        stateData.network = _networkName();
        stateData.saltPrefix = saltPrefix();
        stateData.baoFactory = baoFactory();
    }

    function _networkName() internal view returns (string memory) {
        return string.concat("chain-", _vm.toString(block.chainid));
    }
}
