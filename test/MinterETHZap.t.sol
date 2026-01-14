// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MinterETHZapV2} from "src/minter/MinterETHZap_v2.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockStabilityPool} from "test/mock/MockStabilityPool.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

contract MinterETHZapForkTest is TestMinterSetUp {
    MinterETHZapV2 zap;
    address user1;
    address receiver;

    // Mainnet Lido addresses
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

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

        // Bootstrap minter with initial collateral (needed for price calculations)
        setUp_collateral(1 ether, 1 ether);

        zap = new MinterETHZapV2(minter, address(0));
        vm.label(address(zap), "MinterETHZapV2");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        vm.deal(user1, 100 ether);
    }

    // ============ ETH to Pegged Tests ============

    function test_ZapEthToPegged_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(minter);

        uint256 peggedOut = zap.zapEthToPegged{value: ethAmount}(receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(minter);

        console.log("=== ETH to Pegged Zap Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Pegged Balance:", peggedBalAfter - peggedBalBefore);
        console.log("wstETH in Minter:", wstEthBalAfter);
        console.log("wstETH Deposited:", wstEthBalAfter - wstEthBalBefore);
        console.log("Total Pegged Supply:", IERC20(peggedToken).totalSupply());
        console.log("Minter Pegged Balance:", IMinter(minter).peggedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User ETH Left:", user1.balance);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(wstEthBalAfter, wstEthBalBefore, "wstETH should be deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), minter), 0, "wstETH allowance not cleared");
    }

    function test_ZapEthToPegged_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(MinterETHZapV2.ZeroAmount.selector);
        zap.zapEthToPegged{value: 0}(receiver, 0);

        vm.stopPrank();
    }

    function test_ZapEthToPegged_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(MinterETHZapV2.InvalidAddress.selector);
        zap.zapEthToPegged{value: ethAmount}(address(0), 0);

        vm.stopPrank();
    }

    function test_ZapEthToPegged_Event() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, false);
        emit MinterETHZapV2.ETHZappedToPegged(user1, minter, receiver, ethAmount, 0, 0);

        zap.zapEthToPegged{value: ethAmount}(receiver, 0);

        vm.stopPrank();
    }

    // ============ ETH to Leveraged Tests ============

    function test_ZapEthToLeveraged_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(minter);

        uint256 leveragedOut = zap.zapEthToLeveraged{value: ethAmount}(receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(minter);

        console.log("=== ETH to Leveraged Zap Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("Leveraged Tokens Minted:", leveragedOut);
        console.log("Leveraged Balance:", leveragedBalAfter - leveragedBalBefore);
        console.log("wstETH in Minter:", wstEthBalAfter);
        console.log("wstETH Deposited:", wstEthBalAfter - wstEthBalBefore);
        console.log("Total Leveraged Supply:", IERC20(leveragedToken).totalSupply());
        console.log("Minter Leveraged Balance:", IMinter(minter).leveragedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User ETH Left:", user1.balance);
        console.log("==========================");

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
        assertGt(wstEthBalAfter, wstEthBalBefore, "wstETH should be deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), minter), 0, "wstETH allowance not cleared");
    }

    function test_ZapEthToLeveraged_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(MinterETHZapV2.ZeroAmount.selector);
        zap.zapEthToLeveraged{value: 0}(receiver, 0);

        vm.stopPrank();
    }

    function test_ZapEthToLeveraged_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(MinterETHZapV2.InvalidAddress.selector);
        zap.zapEthToLeveraged{value: ethAmount}(address(0), 0);

        vm.stopPrank();
    }

    function test_ZapEthToLeveraged_Event() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, false);
        emit MinterETHZapV2.ETHZappedToLeveraged(user1, minter, receiver, ethAmount, 0, 0);

        zap.zapEthToLeveraged{value: ethAmount}(receiver, 0);

        vm.stopPrank();
    }

    // ============ stETH to Pegged Tests ============

    function test_ZapStEthToPegged_Success() public {
        // Fund user with ETH first, then submit to get stETH
        vm.deal(user1, 100 ether);

        // Submit ETH to get stETH
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthBalanceBefore = IERC20(STETH).balanceOf(user1);
        uint256 stEthAmount = stEthBalanceBefore / 10; // Use 10% of the stETH

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(minter);
        uint256 userStEthBalBefore = IERC20(STETH).balanceOf(user1);

        uint256 peggedOut = zap.zapStEthToPegged(stEthAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(minter);
        uint256 userStEthBalAfter = IERC20(STETH).balanceOf(user1);

        console.log("=== stETH to Pegged Zap Success ===");
        console.log("stETH Deposited:", stEthAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Pegged Balance:", peggedBalAfter - peggedBalBefore);
        console.log("wstETH in Minter:", wstEthBalAfter);
        console.log("wstETH Deposited:", wstEthBalAfter - wstEthBalBefore);
        console.log("Total Pegged Supply:", IERC20(peggedToken).totalSupply());
        console.log("Minter Pegged Balance:", IMinter(minter).peggedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User stETH Left:", userStEthBalAfter);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(wstEthBalAfter, wstEthBalBefore, "wstETH should be deposited");
        // stETH is a rebasing token, so allow 1 wei tolerance for rebasing
        assertApproxEqAbs(userStEthBalAfter, userStEthBalBefore - stEthAmount, 1, "stETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), minter), 0, "wstETH allowance not cleared");
    }

    function test_ZapStEthToPegged_ZeroAmount() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterETHZapV2.ZeroAmount.selector);
        zap.zapStEthToPegged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapStEthToPegged_InvalidReceiver() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectRevert(MinterETHZapV2.InvalidAddress.selector);
        zap.zapStEthToPegged(stEthAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapStEthToPegged_Event() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterETHZapV2.STETHZappedToPegged(user1, minter, receiver, stEthAmount, 0, 0);

        zap.zapStEthToPegged(stEthAmount, receiver, 0);

        vm.stopPrank();
    }

    // ============ stETH to Leveraged Tests ============

    function test_ZapStEthToLeveraged_Success() public {
        // Fund user with ETH first, then submit to get stETH
        vm.deal(user1, 100 ether);

        // Submit ETH to get stETH
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthBalanceBefore = IERC20(STETH).balanceOf(user1);
        uint256 stEthAmount = stEthBalanceBefore / 10; // Use 10% of the stETH

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(minter);
        uint256 userStEthBalBefore = IERC20(STETH).balanceOf(user1);

        uint256 leveragedOut = zap.zapStEthToLeveraged(stEthAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(minter);
        uint256 userStEthBalAfter = IERC20(STETH).balanceOf(user1);

        console.log("=== stETH to Leveraged Zap Success ===");
        console.log("stETH Deposited:", stEthAmount);
        console.log("Leveraged Tokens Minted:", leveragedOut);
        console.log("Leveraged Balance:", leveragedBalAfter - leveragedBalBefore);
        console.log("wstETH in Minter:", wstEthBalAfter);
        console.log("wstETH Deposited:", wstEthBalAfter - wstEthBalBefore);
        console.log("Total Leveraged Supply:", IERC20(leveragedToken).totalSupply());
        console.log("Minter Leveraged Balance:", IMinter(minter).leveragedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User stETH Left:", userStEthBalAfter);
        console.log("==========================");

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
        assertGt(wstEthBalAfter, wstEthBalBefore, "wstETH should be deposited");
        // stETH is a rebasing token, so allow 1 wei tolerance for rebasing
        assertApproxEqAbs(userStEthBalAfter, userStEthBalBefore - stEthAmount, 1, "stETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), minter), 0, "wstETH allowance not cleared");
    }

    function test_ZapStEthToLeveraged_ZeroAmount() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterETHZapV2.ZeroAmount.selector);
        zap.zapStEthToLeveraged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapStEthToLeveraged_InvalidReceiver() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectRevert(MinterETHZapV2.InvalidAddress.selector);
        zap.zapStEthToLeveraged(stEthAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapStEthToLeveraged_Event() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterETHZapV2.STETHZappedToLeveraged(user1, minter, receiver, stEthAmount, 0, 0);

        zap.zapStEthToLeveraged(stEthAmount, receiver, 0);

        vm.stopPrank();
    }

    // ============ Stability Pool Tests ============

    function test_ZapEthToStabilityPool_Success() public {
        uint256 ethAmount = 1 ether;
        
        // Deploy mock stability pool
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.label(address(stabilityPool), "StabilityPool");
        
        // Allow stability pool
        vm.prank(zap.owner());
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);

        uint256 stabilityPoolBalBefore = stabilityPool.balanceOf(receiver);

        // Get preview for minPeggedOut
        (uint256 previewPegged, ) = zap.previewStabilityPoolFromEth(ethAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100; // 1% slippage
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100; // 1% slippage

        (uint256 peggedOut, uint256 deposited) = zap.zapEthToStabilityPool{value: ethAmount}(
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut
        );

        vm.stopPrank();

        uint256 stabilityPoolBalAfter = stabilityPool.balanceOf(receiver);

        console.log("=== ETH to StabilityPool Zap Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Deposited to StabilityPool:", deposited);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
        assertEq(stabilityPoolBalAfter, stabilityPoolBalBefore + deposited, "Stability pool balance mismatch");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");
    }

    function test_ZapEthToStabilityPool_NotAllowed() public {
        uint256 ethAmount = 1 ether;
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        vm.startPrank(user1);

        vm.expectRevert(MinterETHZapV2.StabilityPoolNotAllowed.selector);
        zap.zapEthToStabilityPool{value: ethAmount}(receiver, 0, address(stabilityPool), 0);

        vm.stopPrank();
    }

    function test_ZapStEthToStabilityPool_Success() public {
        // Fund user with ETH first, then submit to get stETH
        vm.deal(user1, 100 ether);

        // Submit ETH to get stETH
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthBalanceBefore = IERC20(STETH).balanceOf(user1);
        uint256 stEthAmount = stEthBalanceBefore / 10; // Use 10% of the stETH

        // Deploy mock stability pool
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        
        // Allow stability pool
        vm.prank(zap.owner());
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        uint256 stabilityPoolBalBefore = stabilityPool.balanceOf(receiver);

        // Get preview for minPeggedOut
        (uint256 previewPegged, ) = zap.previewStabilityPoolFromStEth(stEthAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100; // 1% slippage
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100; // 1% slippage

        (uint256 peggedOut, uint256 deposited) = zap.zapStEthToStabilityPool(
            stEthAmount,
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut
        );

        vm.stopPrank();

        uint256 stabilityPoolBalAfter = stabilityPool.balanceOf(receiver);

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
        assertEq(stabilityPoolBalAfter, stabilityPoolBalBefore + deposited, "Stability pool balance mismatch");
    }

    // ============ Preview Function Tests ============

    function test_PreviewWstEthFromEth() public {
        uint256 ethAmount = 1 ether;
        uint256 previewWstEth = zap.previewWstEthFromEth(ethAmount);
        
        assertGt(previewWstEth, 0, "Preview should return > 0");
        assertLt(previewWstEth, ethAmount, "wstETH should be less than ETH due to conversion");
        console.log("Preview wstETH from ETH:", previewWstEth);
    }

    function test_PreviewWstEthFromStEth() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;
        uint256 previewWstEth = zap.previewWstEthFromStEth(stEthAmount);
        
        assertGt(previewWstEth, 0, "Preview should return > 0");
        console.log("Preview wstETH from stETH:", previewWstEth);
    }

    function test_PreviewPeggedFromEth() public {
        uint256 ethAmount = 1 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewPeggedFromEth(ethAmount);
        
        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Pegged from ETH:", previewPegged);
        console.log("Preview wstETH from ETH:", previewWstEth);
    }

    function test_PreviewLeveragedFromEth() public {
        uint256 ethAmount = 1 ether;
        (uint256 previewLeveraged, uint256 previewWstEth) = zap.previewLeveragedFromEth(ethAmount);
        
        assertGt(previewLeveraged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Leveraged from ETH:", previewLeveraged);
        console.log("Preview wstETH from ETH:", previewWstEth);
    }

    function test_PreviewPeggedFromStEth() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewPeggedFromStEth(stEthAmount);
        
        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Pegged from stETH:", previewPegged);
        console.log("Preview wstETH from stETH:", previewWstEth);
    }

    function test_PreviewLeveragedFromStEth() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;
        (uint256 previewLeveraged, uint256 previewWstEth) = zap.previewLeveragedFromStEth(stEthAmount);
        
        assertGt(previewLeveraged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Leveraged from stETH:", previewLeveraged);
        console.log("Preview wstETH from stETH:", previewWstEth);
    }

    function test_PreviewStabilityPoolFromEth() public {
        uint256 ethAmount = 1 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewStabilityPoolFromEth(ethAmount);
        
        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        // Should match previewPeggedFromEth since it's the same calculation
        (uint256 peggedFromEth, ) = zap.previewPeggedFromEth(ethAmount);
        assertEq(previewPegged, peggedFromEth, "Should match pegged preview");
        console.log("Preview StabilityPool from ETH:", previewPegged);
    }

    function test_PreviewStabilityPoolFromStEth() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewStabilityPoolFromStEth(stEthAmount);
        
        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        // Should match previewPeggedFromStEth since it's the same calculation
        (uint256 peggedFromStEth, ) = zap.previewPeggedFromStEth(stEthAmount);
        assertEq(previewPegged, peggedFromStEth, "Should match pegged preview");
        console.log("Preview StabilityPool from stETH:", previewPegged);
    }

    // ============ Owner Function Tests ============

    function test_SetStabilityPoolAllowed() public {
        address stabilityPool = makeAddr("stabilityPool");
        
        vm.prank(zap.owner());
        zap.setStabilityPoolAllowed(stabilityPool, true);
        
        assertTrue(zap.allowedStabilityPools(stabilityPool), "Stability pool should be allowed");
        
        vm.prank(zap.owner());
        zap.setStabilityPoolAllowed(stabilityPool, false);
        
        assertFalse(zap.allowedStabilityPools(stabilityPool), "Stability pool should not be allowed");
    }

    function test_SetStabilityPoolAllowed_OnlyOwner() public {
        address stabilityPool = makeAddr("stabilityPool");
        
        vm.prank(user1);
        vm.expectRevert();
        zap.setStabilityPoolAllowed(stabilityPool, true);
    }

    function test_SetReferral() public {
        address newReferral = makeAddr("newReferral");
        
        vm.prank(zap.owner());
        zap.setReferral(newReferral);
        
        assertEq(zap.referral(), newReferral, "Referral should be updated");
    }
}

