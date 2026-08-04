// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MinterUSDCZap_v1} from "@harborzap/zap/upgradeable/MinterUSDCZap_v1.sol";
import {FxSAVEConstants} from "@harborzap/constants/ethereum/FxSAVEConstants.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";

import {TestMinterSetUp} from "@harborzap-test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "@harborzap-test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "@harborzap-test/mock/MockERC20.sol";
import {MockStabilityPool} from "@harborzap-test/mock/MockStabilityPool.sol";

/// @dev Calls a selector with no implementation so the zap's `fallback` runs (revert propagates to test)
interface ITriggerZapFallback {
    function __zapFallbackProbe() external;
}

contract MinterUSDCZapV1ForkTest is TestMinterSetUp {
    bytes32 private constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
    MinterUSDCZap_v1 zap;
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
        zapImpl = address(new MinterUSDCZap_v1(minter));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(
            zapImpl,
            abi.encodeCall(MinterUSDCZap_v1.initialize, (address(this), zapOwner))
        );
        zap = MinterUSDCZap_v1(payable(zapProxy));
        vm.label(address(zap), "MinterUSDCZapV1");

        // Complete ownership transfer from deployer to zapOwner
        zap.transferOwnership(zapOwner);

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        deal(USDC, user1, 10000 * 1e6);
    }

    function test_CollateralManagerAndRouterMatchConstants() public view {
        assertEq(zap.COLLATERAL_MANAGER(), FxSAVEConstants.FXUSD_DIAMOND);
        assertEq(zap.SWAP_ROUTER(), FxSAVEConstants.FXUSD_SWAP_ROUTER);
        assertEq(zap.CONVERT_SELECTOR(), FxSAVEConstants.CONVERT_SELECTOR);
        assertEq(zap.BASE_ASSET(), USDC);
        assertEq(zap.COLLATERAL_ASSET(), FXUSD);
        assertEq(zap.WRAPPED_COLLATERAL_ASSET(), FXSAVE);
    }

    // ============ USDC to Pegged Tests ============

    function test_ZapUsdcToPegged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 peggedOut = zap.zapBaseAssetToPegged(usdcAmount, 0, receiver, 0);

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
        assertEq(IERC20(USDC).allowance(address(zap), zap.COLLATERAL_MANAGER()), 0, "USDC allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapUsdcToPegged_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapBaseAssetToPegged(0, 0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToPegged_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        zap.zapBaseAssetToPegged(usdcAmount, 0, address(0), 0);

        vm.stopPrank();
    }

    // ============ USDC to Leveraged Tests ============

    function test_ZapUsdcToLeveraged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 leveragedOut = zap.zapBaseAssetToLeveraged(usdcAmount, 0, receiver, 0);

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
        uint256 peggedOut = zap.zapCollateralToPegged(fxUsdAmount, 0, receiver, 0);

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
        uint256 leveragedOut = zap.zapCollateralToLeveraged(fxUsdAmount, 0, receiver, 0);

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
        uint256 previewPegged = zap.previewPeggedFromWrappedCollateral(fxSaveAmount);
        uint256 minPeggedOut = (previewPegged * 99) / 100;
        uint256 minStabilityPoolOut = (minPeggedOut * 99) / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapBaseAssetToStabilityPool(
            usdcAmount,
            0,
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut
        );

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
        zap.zapBaseAssetToStabilityPool(usdcAmount, 0, receiver, 0, address(stabilityPool), 0);

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
        uint256 previewPegged = zap.previewPeggedFromWrappedCollateral(fxSaveAmount);
        uint256 minPeggedOut = (previewPegged * 99) / 100;
        uint256 minStabilityPoolOut = (minPeggedOut * 99) / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapCollateralToStabilityPool(
            fxUsdAmount,
            0,
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut
        );

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapFxSaveToStabilityPool_Success() public {
        uint256 fxSaveAmount = 1000 * 1e18;
        deal(FXSAVE, user1, fxSaveAmount);

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        vm.startPrank(user1);
        IERC20(FXSAVE).approve(address(zap), fxSaveAmount);

        uint256 previewPegged = zap.previewStabilityPoolFromWrappedCollateral(fxSaveAmount);
        uint256 minPeggedOut = (previewPegged * 99) / 100;
        uint256 minStabilityPoolOut = (minPeggedOut * 99) / 100;

        (uint256 peggedOut, uint256 deposited) = zap.zapWrappedCollateralToStabilityPool(
            fxSaveAmount,
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut
        );

        vm.stopPrank();

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapFxSaveToStabilityPool_ZeroAmount() public {
        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapWrappedCollateralToStabilityPool(0, receiver, 0, address(stabilityPool), 0);
        vm.stopPrank();
    }

    function test_ZapFxSaveToStabilityPoolWithPermit_Success() public {
        uint256 userPk = 0xA11CE;
        address userPermit = vm.addr(userPk);
        uint256 fxSaveAmount = 1000 * 1e18;
        deal(FXSAVE, userPermit, fxSaveAmount);

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);
        vm.prank(zapOwner);
        zap.setStabilityPoolAllowed(address(stabilityPool), true);

        uint256 nonce = IERC20Permit(FXSAVE).nonces(userPermit);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userPermit, address(zap), fxSaveAmount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(FXSAVE).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        uint256 previewPegged = zap.previewStabilityPoolFromWrappedCollateral(fxSaveAmount);
        uint256 minPeggedOut = (previewPegged * 99) / 100;
        uint256 minStabilityPoolOut = (minPeggedOut * 99) / 100;

        vm.prank(userPermit);
        (uint256 peggedOut, uint256 deposited) = zap.zapWrappedCollateralToStabilityPoolWithPermit(
            fxSaveAmount,
            receiver,
            minPeggedOut,
            address(stabilityPool),
            minStabilityPoolOut,
            deadline,
            v,
            r,
            s
        );

        assertGt(peggedOut, 0, "Should mint pegged tokens");
        assertGt(deposited, 0, "Should deposit to stability pool");
    }

    function test_ZapFxSaveToStabilityPoolWithPermit_ZeroAmount() public {
        uint256 userPk = 0xB0B;
        address userPermit = vm.addr(userPk);

        MockStabilityPool stabilityPool = new MockStabilityPool(peggedToken);

        uint256 nonce = IERC20Permit(FXSAVE).nonces(userPermit);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, userPermit, address(zap), uint256(0), nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(FXSAVE).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.prank(userPermit);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapWrappedCollateralToStabilityPoolWithPermit(0, receiver, 0, address(stabilityPool), 0, deadline, v, r, s);
    }

    // ============ Preview Function Tests ============

    function test_PreviewPeggedFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewPegged = zap.previewPeggedFromWrappedCollateral(fxSaveAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
    }

    function test_ZapName() public view {
        string memory expectedName = string(abi.encodePacked("Minter zap ", IERC20Metadata(peggedToken).name()));
        string memory name = zap.zapName();

        console.log("Minter zap name:", name);

        assertEq(name, expectedName, "Zap name mismatch");
    }

    function test_PreviewLeveragedFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewLeveraged = zap.previewLeveragedFromWrappedCollateral(fxSaveAmount);

        assertGt(previewLeveraged, 0, "Preview should return > 0");
    }

    function test_PreviewStabilityPoolFromFxSave() public view {
        uint256 fxSaveAmount = 1000 * 1e18;
        uint256 previewPegged = zap.previewStabilityPoolFromWrappedCollateral(fxSaveAmount);

        assertGt(previewPegged, 0, "Preview should return > 0");
    }

    function test_PreviewWrappedCollateralFromBase_MatchesFxSaveConvertToShares() public view {
        uint256 usdcAmount = 1000 * 1e6;
        uint256 expected = IERC4626(FXSAVE).convertToShares(usdcAmount * 1e12);
        assertEq(zap.previewWrappedCollateralFromBase(usdcAmount), expected);
    }

    function test_PreviewPeggedFromBase_UsesDryRun() public view {
        uint256 usdcAmount = 1000 * 1e6;
        uint256 wrapped = zap.previewWrappedCollateralFromBase(usdcAmount);
        (, , , uint256 peggedFromDry, , ) = IMinter(minter).mintPeggedTokenDryRun(wrapped);
        (uint256 peggedOut, uint256 wrappedOut) = zap.previewPeggedFromBase(usdcAmount);
        assertEq(wrappedOut, wrapped);
        assertEq(peggedOut, peggedFromDry);
    }

    /// @dev Preview uses ERC4626 + peg model; live zap uses the diamond — expect small drift (tolerance in bps).
    function test_PreviewVsActualZap_WithinBpsTolerance() public {
        uint256 usdcAmount = 1000 * 1e6;
        uint256 previewUsdc = zap.previewWrappedCollateralFromBase(usdcAmount);
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);
        vm.recordLogs();
        zap.zapBaseAssetToPegged(usdcAmount, 0, receiver, 0);
        vm.stopPrank();
        uint256 actualUsdc = _wrappedFromBaseAssetZapEvent(vm.getRecordedLogs());
        _assertRelativeDiffBps(previewUsdc, actualUsdc, 200);

        uint256 fxUsdAmount = 500 * 1e18;
        deal(FXUSD, user1, fxUsdAmount);
        uint256 previewFx = zap.previewWrappedCollateralFromCollateral(fxUsdAmount);
        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);
        vm.recordLogs();
        zap.zapCollateralToPegged(fxUsdAmount, 0, receiver, 0);
        vm.stopPrank();
        uint256 actualFx = _wrappedFromCollateralZapEvent(vm.getRecordedLogs());
        _assertRelativeDiffBps(previewFx, actualFx, 200);
    }

    function _assertRelativeDiffBps(uint256 a, uint256 b, uint256 maxBps) internal pure {
        uint256 diff = a > b ? a - b : b - a;
        uint256 basis = b > 0 ? b : a;
        if (basis == 0) {
            assertEq(diff, 0);
            return;
        }
        assertLe((diff * 10_000) / basis, maxBps, "preview vs actual relative diff");
    }

    function _wrappedFromBaseAssetZapEvent(Vm.Log[] memory logs) internal pure returns (uint256 wrapped) {
        bytes32 sig = keccak256("BaseAssetZappedToPegged(address,address,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (, wrapped, ) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                return wrapped;
            }
        }
        revert("BaseAssetZappedToPegged not found");
    }

    function _wrappedFromCollateralZapEvent(Vm.Log[] memory logs) internal pure returns (uint256 wrapped) {
        bytes32 sig = keccak256("CollateralZappedToPegged(address,address,address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                (, wrapped, ) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                return wrapped;
            }
        }
        revert("CollateralZappedToPegged not found");
    }

    function test_Fallback_FunctionNotFound() public {
        vm.expectRevert(IZapErrors.FunctionNotFound.selector);
        ITriggerZapFallback(address(zap)).__zapFallbackProbe();
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new MinterUSDCZap_v1(minter));

        // Upgrade proxy
        vm.prank(zapOwner);
        zap.upgradeToAndCall(newImpl, "");

        // Verify upgrade worked
        assertEq(UnsafeUpgrades.getImplementationAddress(address(zap)), newImpl, "Implementation should be upgraded");

        // Verify functionality still works
        uint256 usdcAmount = 1000 * 1e6;
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);
        uint256 peggedOut = zap.zapBaseAssetToPegged(usdcAmount, 0, receiver, 0);
        vm.stopPrank();

        assertGt(peggedOut, 0, "Should still work after upgrade");
    }

    function test_Upgrade_OnlyOwner() public {
        address newImpl = address(new MinterUSDCZap_v1(minter));

        vm.prank(user1);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
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
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        zap.setStabilityPoolAllowed(stabilityPool, true);
    }

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
