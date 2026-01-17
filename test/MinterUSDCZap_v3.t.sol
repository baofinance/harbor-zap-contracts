// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {MinterUSDCZap_v3} from "src/zap/upgradeable/MinterUSDCZap_v3.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockStabilityPool} from "test/mock/MockStabilityPool.sol";

contract MinterUSDCZapV3ForkTest is TestMinterSetUp {
    MinterUSDCZap_v3 zap;
    address zapImpl;
    address zapProxy;
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

        // Bootstrap minter with initial collateral (needed for price calculations)
        setUp_collateral(1000 * 1e6, 1000 * 1e6); // 1000 USDC worth of fxSAVE

        // Deploy upgradeable zap
        zapOwner = makeAddr("zapOwner");
        zapImpl = address(new MinterUSDCZap_v3(minter));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(zapImpl, abi.encodeCall(MinterUSDCZap_v3.initialize, (zapOwner)));
        zap = MinterUSDCZap_v3(payable(zapProxy));
        vm.label(address(zap), "MinterUSDCZapV3");

        // Complete ownership transfer from deployer to zapOwner
        zap.transferOwnership(zapOwner);

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        deal(USDC, user1, 10000 * 1e6);
    }

    // ============ USDC to Pegged Tests ============

    function test_ZapUsdcToPegged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 peggedOut = zap.zapUsdcToPegged(usdcAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(minter);

        console.log("=== USDC to Pegged Zap v3 Success ===");
        console.log("USDC Deposited:", usdcAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(fxBalAfter, fxBalBefore, "fxSAVE should be deposited");
        assertEq(IERC20(USDC).balanceOf(user1), 10000 * 1e6 - usdcAmount, "USDC not deducted");

        // Allowances should be cleared
        assertEq(IERC20(USDC).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "USDC allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapUsdcToPegged_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapUsdcToPegged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToPegged_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        zap.zapUsdcToPegged(usdcAmount, address(0), 0);

        vm.stopPrank();
    }

    // ============ USDC to Leveraged Tests ============

    function test_ZapUsdcToLeveraged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 leveragedOut = zap.zapUsdcToLeveraged(usdcAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
    }

    // ============ fxUSD to Pegged Tests ============

    function test_ZapFxUsdToPegged_Success() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 peggedOut = zap.zapFxUsdToPegged(fxUsdAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
    }

    // ============ fxUSD to Leveraged Tests ============

    function test_ZapFxUsdToLeveraged_Success() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 leveragedOut = zap.zapFxUsdToLeveraged(fxUsdAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
    }

    // ============ Stability Pool Tests ============

    function test_ZapUsdcToStabilityPool_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        // Deploy mock stability pool
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        // Allow stability pool
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 fxSaveAmount = 900 * 1e18; // Approximate
        uint256 previewPegged = zap.previewPeggedFromFxSave(fxSaveAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100;
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100;

        (uint256 peggedOut, uint256 deposited) =
            zap.zapUsdcToStabilityPool(usdcAmount, receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut);

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapUsdcToStabilityPool_NotAllowed() public {
        uint256 usdcAmount = 1000 * 1e6;
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(IZapErrors.StabilityPoolNotAllowed.selector);
        zap.zapUsdcToStabilityPool(usdcAmount, receiver, 0, address(stabilityPool), 0);

        vm.stopPrank();
    }

    function test_ZapFxUsdToStabilityPool_Success() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 fxSaveAmount = 900 * 1e18;
        uint256 previewPegged = zap.previewPeggedFromFxSave(fxSaveAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100;
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapFxUsdToStabilityPool(
            fxUsdAmount, receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut
        );

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    // ============ Preview Function Tests ============

    function test_PreviewPeggedFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewPegged = zap.previewPeggedFromFxSave(fxSaveAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
    }

    function test_PreviewLeveragedFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewLeveraged = zap.previewLeveragedFromFxSave(fxSaveAmount);

        assertGt(previewLeveraged, 0, "Preview should return > 0");
    }

    function test_PreviewStabilityPoolFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewPegged = zap.previewStabilityPoolFromFxSave(fxSaveAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new MinterUSDCZap_v3(minter));

        // Upgrade proxy
        vm.prank(zapOwner);
        zap.upgradeToAndCall(newImpl, "");

        // Verify upgrade worked
        assertEq(UnsafeUpgrades.getImplementationAddress(address(zap)), newImpl, "Implementation should be upgraded");

        // Verify functionality still works
        uint256 usdcAmount = 1000 * 1e6;
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);
        uint256 peggedOut = zap.zapUsdcToPegged(usdcAmount, receiver, 0);
        vm.stopPrank();

        assertGt(peggedOut, 0, "Should still work after upgrade");
    }

    function test_Upgrade_OnlyOwner() public {
        address newImpl = address(new MinterUSDCZap_v3(minter));

        vm.prank(user1);
        vm.expectRevert();
        zap.upgradeToAndCall(newImpl, "");
    }

    // ============ Owner Function Tests ============

    function test_SetStabilityPoolAllowed() public {
        address stabilityPool = makeAddr("stabilityPool");

        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(stabilityPool, true);

        assertTrue(zap.allowedStabilityPools(stabilityPool), "Stability pool should be allowed");

        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(stabilityPool, false);

        assertFalse(zap.allowedStabilityPools(stabilityPool), "Stability pool should not be allowed");
    }

    function test_SetStabilityPoolAllowed_OnlyOwner() public {
        address stabilityPool = makeAddr("stabilityPool");

        vm.prank(user1);
        vm.expectRevert();
        zap.setStabilityPoolAllowed(stabilityPool, true);
    }

    function test_RescueEth() public {
        vm.deal(address(zap), 1 ether);

        uint256 ownerBalanceBefore = zapOwner.balance;
        vm.prank(zapOwner);
        zap.rescueEth();

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

