// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {GenesisUSDCZap_v5} from "src/zap/upgradeable/GenesisUSDCZap_v5.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @dev Calls a selector with no implementation so the zap's `fallback` runs (revert propagates to test)
interface ITriggerZapFallback {
    function __zapFallbackProbe() external;
}

contract GenesisUSDCZapV5ForkTest is TestMinterSetUp {
    GenesisUSDCZap_v5 zap;
    address zapImpl;
    address zapProxy;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;
    address zapOwner;

    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

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

        // Deploy Genesis
        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        // Deploy upgradeable zap
        zapOwner = makeAddr("zapOwner");
        zapImpl = address(new GenesisUSDCZap_v5(genesis));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(
            zapImpl, abi.encodeCall(GenesisUSDCZap_v5.initialize, (address(this), zapOwner))
        );
        zap = GenesisUSDCZap_v5(payable(zapProxy));
        vm.label(address(zap), "GenesisUSDCZapV5");

        // Complete ownership transfer from deployer to zapOwner
        zap.transferOwnership(zapOwner);

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        deal(USDC, user1, 10000 * 1e6);
    }

    function test_ZapUsdcToGenesis_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 genBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(genesis);

        uint256 collateralAmount = zap.zapBaseAsset(usdcAmount, 0, receiver);

        vm.stopPrank();

        uint256 genBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(genesis);

        console.log("=== USDC Zap v4 Success ===");
        console.log("USDC Deposited:", usdcAmount);
        console.log("fxSAVE Received:", collateralAmount);
        console.log("Genesis Shares Minted:", genBalAfter - genBalBefore);
        console.log("==========================");

        assertGt(collateralAmount, 0, "Should receive fxSAVE");
        assertEq(genBalAfter, genBalBefore + collateralAmount, "Shares mismatch");
        assertEq(fxBalAfter, fxBalBefore + collateralAmount, "fxSAVE not deposited");
    }

    function test_ZapFxUsdToGenesis_Success() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 genBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 collateralAmount = zap.zapCollateral(fxUsdAmount, 0, receiver);
        vm.stopPrank();

        uint256 genBalAfter = IGenesis(genesis).balanceOf(receiver);

        assertGt(collateralAmount, 0, "Should receive fxSAVE");
        assertEq(genBalAfter, genBalBefore + collateralAmount, "Shares mismatch");
    }

    function test_ZapName() public view {
        string memory expectedName =
            string(abi.encodePacked("Genesis zap ", IERC20Metadata(IGenesis(genesis).PEGGED_TOKEN()).name()));
        string memory name = zap.zapName();

        console.log("Genesis zap name:", name);

        assertEq(name, expectedName, "Zap name mismatch");
    }

    // ============ Preview Function Tests ============

    function test_PreviewGenesisFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewShares = zap.previewSharesFromWrappedCollateral(fxSaveAmount);

        // Genesis uses 1:1 mapping
        assertEq(previewShares, fxSaveAmount, "Preview should return 1:1 shares");
    }

    function test_PreviewGenesisFromFxSave_Zero() public view {
        uint256 previewShares = zap.previewSharesFromWrappedCollateral(0);
        assertEq(previewShares, 0, "Preview should return 0 for zero input");
    }

    /// @dev Oracle-less paths intentionally revert with a dedicated error (not `FunctionNotFound`)
    function test_PreviewNotSupported_OnStubViews() public {
        vm.expectRevert(IZapErrors.PreviewNotSupported.selector);
        zap.previewWrappedCollateralFromBase(1e6);

        vm.expectRevert(IZapErrors.PreviewNotSupported.selector);
        zap.balanceOfBaseAsset(user1);

        vm.expectRevert(IZapErrors.PreviewNotSupported.selector);
        zap.totalValueBaseAsset();
    }

    /// @dev Unknown selectors use `FunctionNotFound`, distinct from unsupported previews
    function test_Fallback_FunctionNotFound() public {
        vm.expectRevert(IZapErrors.FunctionNotFound.selector);
        ITriggerZapFallback(address(zap)).__zapFallbackProbe();
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new GenesisUSDCZap_v5(genesis));

        // Upgrade proxy
        vm.prank(zapOwner);
        zap.upgradeToAndCall(newImpl, "");

        // Verify upgrade worked
        assertEq(UnsafeUpgrades.getImplementationAddress(address(zap)), newImpl, "Implementation should be upgraded");

        // Verify functionality still works
        uint256 usdcAmount = 1000 * 1e6;
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);
        uint256 collateralAmount = zap.zapBaseAsset(usdcAmount, 0, receiver);
        vm.stopPrank();

        assertGt(collateralAmount, 0, "Should still work after upgrade");
    }

    function test_Upgrade_OnlyOwner() public {
        address newImpl = address(new GenesisUSDCZap_v5(genesis));

        vm.prank(user1);
        vm.expectRevert();
        zap.upgradeToAndCall(newImpl, "");
    }

    // ============ Owner Function Tests ============

    function test_RescueNativeAsset() public {
        vm.deal(address(zap), 1 ether);

        uint256 ownerBalanceBefore = zapOwner.balance;
        vm.prank(zapOwner);
        zap.rescueNativeAsset();

        assertEq(zapOwner.balance, ownerBalanceBefore + 1 ether, "ETH should be rescued");
    }

    function test_RescueToken_ProtectedToken() public {
        deal(USDC, address(zap), 1000 * 1e6);

        vm.prank(zapOwner);
        vm.expectRevert(abi.encodeWithSelector(IZapErrors.CannotRescueProtectedToken.selector, USDC));
        zap.rescueToken(USDC);
    }

    function test_RescueToken_UnprotectedToken() public {
        MockERC20 token = new MockERC20("Mock", "MOCK", 18);
        deal(address(token), address(zap), 1000 ether);

        uint256 ownerBalanceBefore = token.balanceOf(zapOwner);
        vm.prank(zapOwner);
        zap.rescueToken(address(token));

        assertEq(token.balanceOf(zapOwner), ownerBalanceBefore + 1000 ether, "Token should be rescued");
    }
}

