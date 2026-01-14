// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {GenesisETHZapV3} from "src/zap/GenesisETHZap_v3.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}

/// @notice Interface for wstETH
interface IWstETHV2 {
    // forge-lint: disable-next-line(mixed-case-function)
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
}

contract GenesisETHZapForkTest is TestMinterSetUp {
    GenesisETHZapV3 zap;
    address genesis;
    address genesisImpl;
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

        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        zap = new GenesisETHZapV3(genesis, address(0));
        vm.label(address(zap), "GenesisETHZapV3");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        vm.deal(user1, 100 ether);
    }

    /// @notice Helper to calculate expected wstETH from ETH amount (for slippage protection)
    function _calculateMinWstEthFromEth(uint256 ethAmount) internal view returns (uint256) {
        uint256 stEthShares = ISTETHV2(STETH).getSharesByPooledEth(ethAmount);
        uint256 wstEthAmount = IWstETHV2(WSTETH).getWstETHByStETH(stEthShares);
        return wstEthAmount * 99 / 100; // 1% slippage buffer
    }

    /// @notice Helper to calculate expected wstETH from stETH amount (for slippage protection)
    function _calculateMinWstEthFromStEth(uint256 stEthAmount) internal view returns (uint256) {
        uint256 wstEthAmount = IWstETHV2(WSTETH).getWstETHByStETH(stEthAmount);
        return wstEthAmount * 99 / 100; // 1% slippage buffer
    }

    function test_ZapEth_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 genesisBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(genesis);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);
        
        uint256 sharesOut = zap.zapEth{value: ethAmount}(receiver, minWstEthOut);

        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(genesis);

        console.log("=== ETH Zap v3 Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("wstETH Received:", sharesOut);
        console.log("Genesis Shares Minted:", genesisBalAfter - genesisBalBefore);
        console.log("wstETH in Genesis:", wstEthBalAfter);
        console.log("User ETH Left:", user1.balance);
        console.log("==========================");

        assertGt(sharesOut, 0, "Should receive wstETH");
        assertEq(genesisBalAfter, genesisBalBefore + sharesOut, "Shares mismatch");
        assertEq(wstEthBalAfter, wstEthBalBefore + sharesOut, "wstETH not deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), genesis), 0, "wstETH allowance not cleared");
    }

    function test_ZapEth_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZapV3.ZeroAmount.selector);
        zap.zapEth{value: 0}(receiver, 0);

        vm.stopPrank();
    }

    function test_ZapEth_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZapV3.ZeroAddress.selector);
        zap.zapEth{value: ethAmount}(address(0), 0);

        vm.stopPrank();
    }

    function test_ZapEth_Event() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);

        // Check that event is emitted with correct user and receiver
        vm.expectEmit(true, true, false, false);
        emit GenesisETHZapV3.ZappedETH(user1, receiver, ethAmount, 0, 0, 0);

        zap.zapEth{value: ethAmount}(receiver, minWstEthOut);

        vm.stopPrank();
    }

    function test_ZapEth_MultipleDeposits() public {
        uint256 eth1 = 1 ether;
        uint256 eth2 = 2 ether;

        vm.startPrank(user1);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut1 = _calculateMinWstEthFromEth(eth1);
        uint256 minWstEthOut2 = _calculateMinWstEthFromEth(eth2);

        uint256 shares1 = zap.zapEth{value: eth1}(receiver, minWstEthOut1);
        uint256 shares2 = zap.zapEth{value: eth2}(receiver, minWstEthOut2);

        vm.stopPrank();

        uint256 total = shares1 + shares2;
        assertEq(IGenesis(genesis).balanceOf(receiver), total, "Total shares wrong");
        assertEq(IERC20(WSTETH).balanceOf(genesis), total, "Total wstETH wrong");
    }

    // ============ stETH Zap Tests ============

    function test_ZapStEth_Success() public {
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

        uint256 genesisBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(genesis);
        uint256 userStEthBalBefore = IERC20(STETH).balanceOf(user1);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromStEth(stEthAmount);
        
        uint256 sharesOut = zap.zapStEth(stEthAmount, receiver, minWstEthOut);

        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(genesis);
        uint256 userStEthBalAfter = IERC20(STETH).balanceOf(user1);

        console.log("=== stETH Zap v3 Success ===");
        console.log("stETH Deposited:", stEthAmount);
        console.log("wstETH Received:", sharesOut);
        console.log("Genesis Shares Minted:", genesisBalAfter - genesisBalBefore);
        console.log("wstETH in Genesis:", wstEthBalAfter);
        console.log("User stETH Left:", userStEthBalAfter);
        console.log("==========================");

        assertGt(sharesOut, 0, "Should receive wstETH");
        assertLe(sharesOut, stEthAmount, "wstETH cannot exceed stETH");
        assertEq(genesisBalAfter, genesisBalBefore + sharesOut, "Shares mismatch");
        assertEq(wstEthBalAfter, wstEthBalBefore + sharesOut, "wstETH not deposited");
        // stETH is a rebasing token, so allow 2 wei tolerance for rebasing
        assertApproxEqAbs(userStEthBalAfter, userStEthBalBefore - stEthAmount, 2, "stETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), genesis), 0, "wstETH allowance not cleared");
    }

    function test_ZapStEth_ZeroAmount() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), type(uint256).max);

        vm.expectRevert(GenesisETHZapV3.ZeroAmount.selector);
        zap.zapStEth(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapStEth_InvalidReceiver() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectRevert(GenesisETHZapV3.ZeroAddress.selector);
        zap.zapStEth(stEthAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapStEth_Event() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromStEth(stEthAmount);

        // Check that event is emitted with correct user and receiver
        vm.expectEmit(true, true, false, false);
        emit GenesisETHZapV3.ZappedStETH(user1, receiver, stEthAmount, 0, 0, 0);

        zap.zapStEth(stEthAmount, receiver, minWstEthOut);

        vm.stopPrank();
    }

    function test_ZapStEth_MultipleDeposits() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthBalance = IERC20(STETH).balanceOf(user1);
        uint256 amt1 = stEthBalance / 10;
        uint256 amt2 = stEthBalance / 5;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), type(uint256).max);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut1 = _calculateMinWstEthFromStEth(amt1);
        uint256 minWstEthOut2 = _calculateMinWstEthFromStEth(amt2);

        uint256 shares1 = zap.zapStEth(amt1, receiver, minWstEthOut1);
        uint256 shares2 = zap.zapStEth(amt2, receiver, minWstEthOut2);

        vm.stopPrank();

        uint256 total = shares1 + shares2;
        assertEq(IGenesis(genesis).balanceOf(receiver), total, "Total shares wrong");
        assertEq(IERC20(WSTETH).balanceOf(genesis), total, "Total wstETH wrong");
    }

    // ============ View Function Tests ============

    function test_BalanceOfETH() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);
        uint256 sharesOut = zap.zapEth{value: ethAmount}(receiver, minWstEthOut);
        vm.stopPrank();

        uint256 ethBalance = zap.balanceOfETH(receiver);
        uint256 stEthBalance = zap.balanceOfStETH(receiver);

        assertGt(ethBalance, 0, "ETH balance should be > 0");
        assertGt(stEthBalance, 0, "stETH balance should be > 0");
        // ETH balance should be close to the deposited amount (may vary due to conversion rates)
        assertGe(ethBalance, ethAmount * 90 / 100, "ETH balance should be reasonable");
    }

    function test_BalanceOfStETH() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);
        uint256 sharesOut = zap.zapEth{value: ethAmount}(receiver, minWstEthOut);
        vm.stopPrank();

        uint256 stEthBalance = zap.balanceOfStETH(receiver);
        
        assertGt(stEthBalance, 0, "stETH balance should be > 0");
        // stETH balance can be higher than shares due to appreciation
        // Just verify it's reasonable
        assertGt(stEthBalance, sharesOut * 90 / 100, "stETH balance should be reasonable");
    }

    function test_TotalValueETH() public {
        uint256 ethAmount1 = 1 ether;
        uint256 ethAmount2 = 2 ether;

        vm.startPrank(user1);
        // Get previews for minWstEthOut
        uint256 minWstEthOut1 = _calculateMinWstEthFromEth(ethAmount1);
        uint256 minWstEthOut2 = _calculateMinWstEthFromEth(ethAmount2);
        
        uint256 shares1 = zap.zapEth{value: ethAmount1}(receiver, minWstEthOut1);
        uint256 shares2 = zap.zapEth{value: ethAmount2}(receiver, minWstEthOut2);
        vm.stopPrank();

        uint256 totalValue = zap.totalValueETH();
        
        assertGt(totalValue, 0, "Total value should be > 0");
        // Total value should be reasonable compared to deposits
        assertGe(totalValue, (ethAmount1 + ethAmount2) * 90 / 100, "Total value should be reasonable");
    }


    function test_BalanceOfETH_ZeroBalance() public {
        uint256 balance = zap.balanceOfETH(receiver);
        assertEq(balance, 0, "Balance should be 0 for user with no deposits");
    }

    function test_TotalValueETH_ZeroSupply() public {
        // Before any deposits, total value should be 0
        uint256 totalValue = zap.totalValueETH();
        assertEq(totalValue, 0, "Total value should be 0 when no deposits");
    }

}
