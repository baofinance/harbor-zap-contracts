// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {MinterETHZap_v3} from "src/zap/upgradeable/MinterETHZap_v3.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";
import {MockStabilityPool} from "test/mock/MockStabilityPool.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

interface IWstETHWrapV2 {
    function wrap(uint256 stEthAmount) external returns (uint256);
}

contract MinterETHZapV3ForkTest is TestMinterSetUp {
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    MinterETHZap_v3 zap;
    address zapImpl;
    address zapProxy;
    address user1;
    address receiver;
    address zapOwner;

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

        // Deploy upgradeable zap
        zapOwner = makeAddr("zapOwner");
        zapImpl = address(new MinterETHZap_v3(minter, address(0)));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(
            zapImpl, abi.encodeCall(MinterETHZap_v3.initialize, (address(this), zapOwner, address(0)))
        );
        zap = MinterETHZap_v3(payable(zapProxy));
        vm.label(address(zap), "MinterETHZapV3");

        // Complete ownership transfer from deployer to zapOwner
        // During proxy initialization, msg.sender (deployer) becomes owner, and zapOwner is set as pending owner
        zap.transferOwnership(zapOwner);

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

        console.log("=== ETH to Pegged Zap v3 Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(wstEthBalAfter, wstEthBalBefore, "wstETH should be deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");
    }

    function test_ZapEthToPegged_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapEthToPegged{value: 0}(receiver, 0);

        vm.stopPrank();
    }

    function test_ZapEthToPegged_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        zap.zapEthToPegged{value: ethAmount}(address(0), 0);

        vm.stopPrank();
    }

    // ============ ETH to Leveraged Tests ============

    function test_ZapEthToLeveraged_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 leveragedOut = zap.zapEthToLeveraged{value: ethAmount}(receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
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
        uint256 peggedOut = zap.zapStEthToPegged(stEthAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
    }

    // ============ stETH to Leveraged Tests ============

    function test_ZapStEthToLeveraged_Success() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 leveragedOut = zap.zapStEthToLeveraged(stEthAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
    }

    // ============ Stability Pool Tests ============

    function test_ZapEthToStabilityPool_Success() public {
        uint256 ethAmount = 1 ether;

        // Deploy mock stability pool
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.label(address(stabilityPool), "StabilityPool");

        // Allow stability pool
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);

        uint256 stabilityPoolBalBefore = stabilityPool.balanceOf(receiver);

        // Get preview for minPeggedOut
        (uint256 previewPegged,) = zap.previewStabilityPoolFromEth(ethAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100; // 1% slippage
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100; // 1% slippage

        (uint256 peggedOut, uint256 deposited) = zap.zapEthToStabilityPool{value: ethAmount}(
            receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut
        );

        vm.stopPrank();

        uint256 stabilityPoolBalAfter = stabilityPool.balanceOf(receiver);

        console.log("=== ETH to StabilityPool Zap v3 Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Deposited to StabilityPool:", deposited);
        console.log("==========================");

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
        assertEq(stabilityPoolBalAfter, stabilityPoolBalBefore + deposited, "Stability pool balance mismatch");
    }

    function test_ZapEthToStabilityPool_NotAllowed() public {
        uint256 ethAmount = 1 ether;
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        vm.startPrank(user1);

        vm.expectRevert(IZapErrors.StabilityPoolNotAllowed.selector);
        zap.zapEthToStabilityPool{value: ethAmount}(receiver, 0, address(stabilityPool), 0);

        vm.stopPrank();
    }

    function test_ZapStEthToStabilityPool_Success() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = 10 ether;

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        (uint256 previewPegged,) = zap.previewStabilityPoolFromStEth(stEthAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100;
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapStEthToStabilityPool(
            stEthAmount, receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut
        );

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapWstEthToStabilityPool_Success() public {
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        uint256 stEthAmount = 10 ether;
        IERC20(STETH).approve(WSTETH, stEthAmount);
        IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        vm.stopPrank();

        uint256 wstEthAmount = IERC20(WSTETH).balanceOf(user1);
        assertGt(wstEthAmount, 0, "Should receive wstETH");

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(WSTETH).approve(address(zap), wstEthAmount);

        uint256 previewPegged = zap.previewStabilityPoolFromWstEth(wstEthAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100;
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapWstEthToStabilityPool(
            wstEthAmount, receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut
        );

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapWstEthToStabilityPoolWithPermit_Success() public {
        uint256 userPk = 0xA11CE;
        address userPermit = vm.addr(userPk);
        vm.deal(userPermit, 100 ether);

        vm.startPrank(userPermit);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        uint256 stEthAmount = 10 ether;
        IERC20(STETH).approve(WSTETH, stEthAmount);
        IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        uint256 wstEthAmount = IERC20(WSTETH).balanceOf(userPermit);
        vm.stopPrank();

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        uint256 nonce = IERC20Permit(WSTETH).nonces(userPermit);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, userPermit, address(zap), wstEthAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(WSTETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        uint256 previewPegged = zap.previewStabilityPoolFromWstEth(wstEthAmount);
        uint256 minPeggedOut = previewPegged * 99 / 100;
        uint256 minStabilityPoolOut = minPeggedOut * 99 / 100;

        vm.prank(userPermit);
        (uint256 peggedOut, uint256 deposited) = zap.zapWstEthToStabilityPoolWithPermit(
            wstEthAmount, receiver, minPeggedOut, address(stabilityPool), minStabilityPoolOut, deadline, v, r, s
        );

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapWstEthToStabilityPoolWithPermit_ZeroAmount() public {
        uint256 userPk = 0xB0B;
        address userPermit = vm.addr(userPk);

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        uint256 nonce = IERC20Permit(WSTETH).nonces(userPermit);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, userPermit, address(zap), uint256(0), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(WSTETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.prank(userPermit);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapWstEthToStabilityPoolWithPermit(0, receiver, 0, address(stabilityPool), 0, deadline, v, r, s);
    }

    function test_ZapWstEthToStabilityPool_ZeroAmount() public {
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapWstEthToStabilityPool(0, receiver, 0, address(stabilityPool), 0);
        vm.stopPrank();
    }

    // ============ Preview Function Tests ============

    function test_PreviewWstEthFromEth() public view {
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

    function test_PreviewPeggedFromEth() public view {
        uint256 ethAmount = 1 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewPeggedFromEth(ethAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Pegged from ETH:", previewPegged);
        console.log("Preview wstETH from ETH:", previewWstEth);
    }

    function test_PreviewLeveragedFromEth() public view {
        uint256 ethAmount = 1 ether;
        (uint256 previewLeveraged, uint256 previewWstEth) = zap.previewLeveragedFromEth(ethAmount);

        assertGt(previewLeveraged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        console.log("Preview Leveraged from ETH:", previewLeveraged);
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
    }

    function test_PreviewStabilityPoolFromEth() public view {
        uint256 ethAmount = 1 ether;
        (uint256 previewPegged, uint256 previewWstEth) = zap.previewStabilityPoolFromEth(ethAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
        assertGt(previewWstEth, 0, "Preview wstETH should return > 0");
        // Should match previewPeggedFromEth since it's the same calculation
        (uint256 peggedFromEth,) = zap.previewPeggedFromEth(ethAmount);
        assertEq(previewPegged, peggedFromEth, "Should match pegged preview");
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
        (uint256 peggedFromStEth,) = zap.previewPeggedFromStEth(stEthAmount);
        assertEq(previewPegged, peggedFromStEth, "Should match pegged preview");
    }

    function test_PreviewStabilityPoolFromWstEth() public view {
        uint256 wstEthAmount = 1 ether;
        uint256 previewPegged = zap.previewStabilityPoolFromWstEth(wstEthAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new MinterETHZap_v3(minter, address(0)));

        // Upgrade proxy
        vm.prank(zapOwner);
        zap.upgradeToAndCall(newImpl, "");

        // Verify upgrade worked
        assertEq(UnsafeUpgrades.getImplementationAddress(address(zap)), newImpl, "Implementation should be upgraded");

        // Verify functionality still works
        uint256 ethAmount = 1 ether;
        vm.startPrank(user1);
        uint256 peggedOut = zap.zapEthToPegged{value: ethAmount}(receiver, 0);
        vm.stopPrank();

        assertGt(peggedOut, 0, "Should still work after upgrade");
    }

    function test_Upgrade_OnlyOwner() public {
        address newImpl = address(new MinterETHZap_v3(minter, address(0)));

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

    function test_SetReferral() public {
        address newReferral = makeAddr("newReferral");

        vm.prank(zapOwner);
        zap.setReferral(newReferral);

        assertEq(zap.referral(), newReferral, "Referral should be updated");
    }

    function test_RescueEth() public {
        vm.deal(address(zap), 1 ether);

        uint256 ownerBalanceBefore = zapOwner.balance;
        vm.prank(zapOwner);
        zap.rescueEth();

        assertEq(zapOwner.balance, ownerBalanceBefore + 1 ether, "ETH should be rescued");
    }

    function test_RescueToken_ProtectedToken() public {
        // Use real stETH minting instead of deal() since stETH has complex proxy storage
        vm.deal(address(this), 1 ether);
        ISTETHV2(STETH).submit{value: 1 ether}(address(0));
        uint256 stEthBalance = IERC20(STETH).balanceOf(address(this));
        // forgefmt: disable-next-item
        require(IERC20(STETH).transfer(address(zap), stEthBalance), "Transfer failed");

        vm.prank(zapOwner);
        vm.expectRevert(abi.encodeWithSelector(IZapErrors.CannotRescueProtectedToken.selector, STETH));
        zap.rescueToken(STETH);
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

