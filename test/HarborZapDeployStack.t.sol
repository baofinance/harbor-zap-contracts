// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaoFactoryTestLib} from "@bao-test/BaoFactoryTestLib.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";

import {HarborZapDeployStack} from "@harborzap-script/src/HarborZapDeployStack.sol";
import {GenesisETHZap_v1} from "@harborzap/zap/upgradeable/GenesisETHZap_v1.sol";
import {GenesisUSDCZap_v1} from "@harborzap/zap/upgradeable/GenesisUSDCZap_v1.sol";
import {MinterETHZap_v1} from "@harborzap/zap/upgradeable/MinterETHZap_v1.sol";
import {MinterUSDCZap_v1} from "@harborzap/zap/upgradeable/MinterUSDCZap_v1.sol";

import {TestMinterSetUp} from "@harborzap-test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "@harborzap-test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "@harborzap-test/mock/MockERC20.sol";

/// @notice Concrete harness over the abstract `HarborZapDeployStack`, exposing the internal deploy
///         functions so the real CREATE3 deploy path (predict → deploy impl → deploy proxy → record →
///         ownership handoff) is exercised end to end in tests. The harness itself registers as the
///         BaoFactory operator and acts as the deployer owner, exactly like the deploy script contract.
contract ZapDeployStackHarness is HarborZapDeployStack {
    constructor(string memory marketKey_) {
        _setMarketKey(marketKey_);
    }

    function ensureFactory() external {
        BaoFactoryTestLib.ensureBaoFactory();
    }

    function predict(string memory key) external returns (address) {
        return _predictAddress(key);
    }

    function marketKey() external view returns (string memory) {
        return _market();
    }

    function defaultStatePath() external view returns (string memory) {
        return _defaultStatePath();
    }

    function transferAll() external {
        _transferAllOwnerships();
    }

    function pendingCount() external view returns (uint256) {
        return _pendingOwnershipCount();
    }

    /// @notice Deploy the ETH-market zaps twice against one fresh state: the first pass takes the
    ///         real deploy path, the second must hit the already-in-state skip branch and return the
    ///         same predicted addresses without redeploying.
    function deployEthZapsTwice(
        address genesis,
        address minter,
        address deployer
    ) external returns (address genesisZap, address minterZap, address genesisZapAgain, address minterZapAgain) {
        DeploymentTypes.State memory stateData = DeploymentState.fresh(saltPrefix(), "test");
        stateData.baoFactory = baoFactory();
        genesisZap = deployGenesisEthZap(stateData, genesis, deployer);
        minterZap = deployMinterEthZap(stateData, minter, deployer);
        genesisZapAgain = deployGenesisEthZap(stateData, genesis, deployer);
        minterZapAgain = deployMinterEthZap(stateData, minter, deployer);
    }

    /// @notice USDC-market equivalent of `deployEthZapsTwice`.
    function deployUsdcZapsTwice(
        address genesis,
        address minter,
        address deployer
    ) external returns (address genesisZap, address minterZap, address genesisZapAgain, address minterZapAgain) {
        DeploymentTypes.State memory stateData = DeploymentState.fresh(saltPrefix(), "test");
        stateData.baoFactory = baoFactory();
        genesisZap = deployGenesisUsdcZap(stateData, genesis, deployer);
        minterZap = deployMinterUsdcZap(stateData, minter, deployer);
        genesisZapAgain = deployGenesisUsdcZap(stateData, genesis, deployer);
        minterZapAgain = deployMinterUsdcZap(stateData, minter, deployer);
    }
}

/// @notice Offline unit tests (no fork) for the `HarborZapFactoryDeployer` configuration surface:
///         fixed multisig owner/treasury, salt-prefix namespacing, and state-file path resolution.
contract HarborZapFactoryDeployerTest is Test {
    address constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    function test_OwnerAndTreasury_AreHarborMultisig() public {
        // The deploy stack always hands ownership and treasury to the fixed Harbor multisig.
        ZapDeployStackHarness harness = new ZapDeployStackHarness("");
        assertEq(harness.owner(), HARBOR_MULTISIG, "owner is multisig");
        assertEq(harness.treasury(), HARBOR_MULTISIG, "treasury is multisig");
    }

    function test_SaltPrefix_RootWithoutMarketKey() public {
        // Without a market key the CREATE3 namespace is the bare root prefix.
        ZapDeployStackHarness harness = new ZapDeployStackHarness("");
        assertEq(harness.saltPrefix(), "harbor_zap_v1", "root salt prefix");
        assertEq(harness.marketKey(), "", "no market key");
    }

    function test_SaltPrefix_IncludesMarketKey() public {
        // A market key namespaces the CREATE3 salts so multiple markets can coexist on one chain.
        ZapDeployStackHarness harness = new ZapDeployStackHarness("ETH");
        assertEq(harness.saltPrefix(), "harbor_zap_v1_ETH", "market-scoped salt prefix");
        assertEq(harness.marketKey(), "ETH", "market key stored");
    }

    function test_DefaultStatePath_PerChainAndMarket() public {
        // The default state file is per-chain, and per-market when a market key is set.
        ZapDeployStackHarness rootHarness = new ZapDeployStackHarness("");
        assertEq(
            rootHarness.defaultStatePath(),
            string.concat("deployments/state-", vm.toString(block.chainid), ".json"),
            "per-chain path"
        );

        ZapDeployStackHarness marketHarness = new ZapDeployStackHarness("ETH");
        assertEq(
            marketHarness.defaultStatePath(),
            string.concat("deployments/state-", vm.toString(block.chainid), "-ETH.json"),
            "per-chain per-market path"
        );
    }
}

/// @notice Mainnet-fork tests driving `HarborZapDeployStack` for the ETH market: both zaps are
///         CREATE3-deployed at their predicted addresses, re-runs skip idempotently, and ownership
///         is handed to the Harbor multisig.
contract HarborZapDeployStackEthForkTest is TestMinterSetUp {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    ZapDeployStackHarness harness;
    address genesis;

    function setUpFork() internal override {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        feeReceiver = makeAddr("feeReceiver");
        owner = makeAddr("owner");

        priceOracle = address(new MockWrappedPriceOracle());
        vm.label(priceOracle, "priceOracle");

        setUp_leveragedToken();
        peggedToken = address(new MockERC20("BaoUSD", "BAOUSD", 18));
        vm.label(peggedToken, "pegged");
        peggedTokenBurnSig = "burnFrom(address,uint256)";

        wrappedCollateralToken = WSTETH;
        collateralToken = STETH;

        setUp_reservePool();
    }

    function setUp() public override {
        super.setUp();

        address genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        // Unique market key so the CREATE3 salts cannot collide with any real deployment
        // already present on the mainnet fork.
        harness = new ZapDeployStackHarness("STACKTEST_ETH");
        harness.ensureFactory();
    }

    function test_DeployEthZaps_PredictedAddresses_SkipOnRerun_OwnershipHandoff() public {
        // The stack deploys both ETH-market zaps at their CREATE3-predicted addresses with the
        // harness as deployer-owner and the multisig pending; a second deploy against the same
        // state skips and returns the same addresses; the final handoff makes the multisig owner.
        (address genesisZap, address minterZap, address genesisZapAgain, address minterZapAgain) = harness
            .deployEthZapsTwice(genesis, minter, address(harness));

        assertEq(genesisZap, harness.predict("genesisEthZap"), "genesis zap at predicted address");
        assertEq(minterZap, harness.predict("minterEthZap"), "minter zap at predicted address");
        assertGt(genesisZap.code.length, 0, "genesis zap proxy has code");
        assertGt(minterZap.code.length, 0, "minter zap proxy has code");

        assertEq(genesisZapAgain, genesisZap, "re-run returns same genesis zap");
        assertEq(minterZapAgain, minterZap, "re-run returns same minter zap");

        // Immutable wiring baked in by the deploy.
        assertEq(GenesisETHZap_v1(payable(genesisZap)).GENESIS(), genesis, "genesis wired");
        assertEq(MinterETHZap_v1(payable(minterZap)).MINTER(), minter, "minter wired");

        // Deployer owns until the in-run handoff; the multisig is pending.
        assertEq(IHarborOwnable(genesisZap).owner(), address(harness), "harness owns genesis zap pre-handoff");
        assertEq(IHarborOwnable(minterZap).owner(), address(harness), "harness owns minter zap pre-handoff");
        assertEq(harness.pendingCount(), 2, "both proxies registered for handoff");

        harness.transferAll();

        assertEq(IHarborOwnable(genesisZap).owner(), HARBOR_MULTISIG, "multisig owns genesis zap");
        assertEq(IHarborOwnable(minterZap).owner(), HARBOR_MULTISIG, "multisig owns minter zap");
        assertEq(harness.pendingCount(), 0, "handoff queue cleared");
    }
}

/// @notice Mainnet-fork tests driving `HarborZapDeployStack` for the USDC market (fxSAVE wrapped
///         collateral): both zaps deploy at predicted addresses and ownership hands off.
contract HarborZapDeployStackUsdcForkTest is TestMinterSetUp {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address constant HARBOR_MULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    ZapDeployStackHarness harness;
    address genesis;

    function setUpFork() internal override {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        feeReceiver = makeAddr("feeReceiver");
        owner = makeAddr("owner");

        priceOracle = address(new MockWrappedPriceOracle());
        vm.label(priceOracle, "priceOracle");

        setUp_leveragedToken();
        peggedToken = address(new MockERC20("BaoUSD", "BAOUSD", 18));
        vm.label(peggedToken, "pegged");
        peggedTokenBurnSig = "burnFrom(address,uint256)";

        wrappedCollateralToken = FXSAVE;
        collateralToken = USDC;

        setUp_reservePool();
    }

    function setUp() public override {
        super.setUp();

        address genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        harness = new ZapDeployStackHarness("STACKTEST_USDC");
        harness.ensureFactory();
    }

    function test_DeployUsdcZaps_PredictedAddresses_SkipOnRerun_OwnershipHandoff() public {
        // Same contract as the ETH-market test, for the USDC/fxSAVE zap pair.
        (address genesisZap, address minterZap, address genesisZapAgain, address minterZapAgain) = harness
            .deployUsdcZapsTwice(genesis, minter, address(harness));

        assertEq(genesisZap, harness.predict("genesisUsdcZap"), "genesis zap at predicted address");
        assertEq(minterZap, harness.predict("minterUsdcZap"), "minter zap at predicted address");
        assertGt(genesisZap.code.length, 0, "genesis zap proxy has code");
        assertGt(minterZap.code.length, 0, "minter zap proxy has code");

        assertEq(genesisZapAgain, genesisZap, "re-run returns same genesis zap");
        assertEq(minterZapAgain, minterZap, "re-run returns same minter zap");

        assertEq(GenesisUSDCZap_v1(payable(genesisZap)).GENESIS(), genesis, "genesis wired");
        assertEq(MinterUSDCZap_v1(payable(minterZap)).MINTER(), minter, "minter wired");

        assertEq(harness.pendingCount(), 2, "both proxies registered for handoff");
        harness.transferAll();
        assertEq(IHarborOwnable(genesisZap).owner(), HARBOR_MULTISIG, "multisig owns genesis zap");
        assertEq(IHarborOwnable(minterZap).owner(), HARBOR_MULTISIG, "multisig owns minter zap");
    }
}
