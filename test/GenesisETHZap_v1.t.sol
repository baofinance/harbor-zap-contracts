// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GenesisETHZap_v1} from "@harborzap/zap/upgradeable/GenesisETHZap_v1.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "@harborzap-test/Minter_base.t.sol";
import {ForkConstants} from "@harborzap-test/ForkConstants.sol";
import {MockWrappedPriceOracle} from "@harborzap-test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "@harborzap-test/mock/MockERC20.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
    function getSharesByPooledEth(uint256 _pooledEthAmount) external view returns (uint256);
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
}

/// @notice Interface for wstETH
interface IWstETHV2 {
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
}

/// @dev Calls a selector with no implementation so the zap's `fallback` runs (revert propagates to test)
interface ITriggerZapFallback {
    function __zapFallbackProbe() external;
}

/// @notice Genesis stand-in reporting a wrapped collateral token the zap was not built for; exercises
///         the constructor's `WrappedCollateralMismatch` guard.
contract MockWrongTokenGenesis {
    address public constant WRAPPED_COLLATERAL_TOKEN = address(0xBEEF);
}

/// @notice Genesis stand-in that consumes the wrapped collateral 1:1 but credits one share less than
///         deposited; exercises the zap's `MintMismatchExpected` guard on the deposit path.
contract MockShortMintGenesis {
    address public immutable WRAPPED_COLLATERAL_TOKEN;
    mapping(address => uint256) public balanceOf;

    constructor(address wrappedCollateralToken_) {
        WRAPPED_COLLATERAL_TOKEN = wrappedCollateralToken_;
    }

    function deposit(uint256 collateralIn, address receiver) external {
        // forgefmt: disable-next-item
        require(
            IERC20(WRAPPED_COLLATERAL_TOKEN).transferFrom(msg.sender, address(this), collateralIn),
            "transfer failed"
        );
        balanceOf[receiver] += collateralIn - 1;
    }
}

contract GenesisETHZapV1ForkTest is TestMinterSetUp {
    GenesisETHZap_v1 zap;
    address zapImpl;
    address zapProxy;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;
    address zapOwner;

    // Mainnet Lido addresses
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    function setUpFork() internal override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), ForkConstants.MAINNET_FORK_BLOCK);

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

        // Deploy Genesis
        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        // Deploy upgradeable zap
        zapOwner = makeAddr("zapOwner");
        zapImpl = address(new GenesisETHZap_v1(genesis));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(
            zapImpl,
            abi.encodeCall(GenesisETHZap_v1.initialize, (address(this), zapOwner))
        );
        zap = GenesisETHZap_v1(payable(zapProxy));
        vm.label(address(zap), "GenesisETHZapV1");

        // Complete ownership transfer from deployer to zapOwner
        zap.transferOwnership(zapOwner);

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        vm.deal(user1, 100 ether);
    }

    /// @notice Helper to calculate expected wstETH from ETH amount (for slippage protection)
    function _calculateMinWstEthFromEth(uint256 ethAmount) internal view returns (uint256) {
        // Use the preview function from the contract
        uint256 wstEthAmount = zap.previewWrappedCollateralFromBase(ethAmount);
        return (wstEthAmount * 99) / 100; // 1% slippage buffer
    }

    /// @notice Helper to calculate expected wstETH from stETH amount (for slippage protection)
    function _calculateMinWstEthFromStEth(uint256 stEthAmount) internal view returns (uint256) {
        uint256 wstEthAmount = IWstETHV2(WSTETH).getWstETHByStETH(stEthAmount);
        return (wstEthAmount * 99) / 100; // 1% slippage buffer
    }

    function test_ZapEth_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 genesisBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(genesis);

        // Calculate minWstEthOut with 1% slippage buffer
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);

        uint256 sharesOut = zap.zapNativeAsset{value: ethAmount}(receiver, minWstEthOut, 0);

        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(genesis);

        console.log("=== ETH Zap v1 Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("wstETH Received:", sharesOut);
        console.log("Genesis Shares Minted:", genesisBalAfter - genesisBalBefore);
        console.log("==========================");

        assertGt(sharesOut, 0, "Should receive wstETH");
        assertEq(genesisBalAfter, genesisBalBefore + sharesOut, "Shares mismatch");
        assertEq(wstEthBalAfter, wstEthBalBefore + sharesOut, "wstETH not deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");
    }

    function test_ZapName() public view {
        string memory expectedName = string(
            abi.encodePacked("Genesis zap ", IERC20Metadata(IGenesis(genesis).PEGGED_TOKEN()).name())
        );
        string memory name = zap.zapName();

        console.log("Genesis zap name:", name);

        assertEq(name, expectedName, "Zap name mismatch");
    }

    /// @dev ETH zap has no fxUSD diamond path; getters exist for ABI parity with USDC Genesis zap.
    function test_FxUsdPathImmutablesAreZero() public view {
        assertEq(zap.COLLATERAL_MANAGER(), address(0));
        assertEq(zap.SWAP_ROUTER(), address(0));
        assertEq(zap.CONVERT_SELECTOR(), bytes4(0));
    }

    function test_ZapStEth_Success() public {
        // Use real stETH minting instead of deal() since stETH has complex proxy storage
        vm.deal(user1, 100 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 100 ether}(address(0));
        vm.stopPrank();

        uint256 stEthAmount = IERC20(STETH).balanceOf(user1);
        require(stEthAmount >= 1 ether, "Not enough stETH");

        vm.startPrank(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        uint256 genesisBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 minWstEthOut = _calculateMinWstEthFromStEth(stEthAmount);

        uint256 sharesOut = zap.zapCollateral(stEthAmount, minWstEthOut, receiver);
        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);

        assertGt(sharesOut, 0, "Should receive wstETH");
        assertEq(genesisBalAfter, genesisBalBefore + sharesOut, "Shares mismatch");
    }

    // ============ Preview Function Tests ============

    function test_PreviewWstEthFromEth() public view {
        uint256 ethAmount = 1 ether;
        uint256 previewWstEth = zap.previewWrappedCollateralFromBase(ethAmount);

        assertGt(previewWstEth, 0, "Preview should return > 0");
        console.log("Preview wstETH from ETH:", previewWstEth);
    }

    function test_PreviewWstEthFromStEth() public view {
        uint256 stEthAmount = 1 ether;
        uint256 previewWstEth = zap.previewWrappedCollateralFromCollateral(stEthAmount);

        assertGt(previewWstEth, 0, "Preview should return > 0");
    }

    function test_PreviewGenesisFromEth() public view {
        uint256 ethAmount = 1 ether;
        (uint256 previewShares, ) = zap.previewSharesFromBase(ethAmount);

        assertGt(previewShares, 0, "Preview should return > 0");
        // Should match previewWrappedCollateralFromBase since Genesis uses 1:1 mapping
        assertEq(previewShares, zap.previewWrappedCollateralFromBase(ethAmount), "Should match wstETH preview");
    }

    function test_PreviewGenesisFromStEth() public view {
        uint256 stEthAmount = 1 ether;
        (uint256 previewShares, ) = zap.previewSharesFromCollateral(stEthAmount);

        assertGt(previewShares, 0, "Preview should return > 0");
        // Should match previewWrappedCollateralFromCollateral since Genesis uses 1:1 mapping
        assertEq(previewShares, zap.previewWrappedCollateralFromCollateral(stEthAmount), "Should match wstETH preview");
    }

    // ============ View Function Tests ============

    function test_BalanceOfETH() public {
        uint256 ethAmount = 1 ether;
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);

        vm.startPrank(user1);
        zap.zapNativeAsset{value: ethAmount}(receiver, minWstEthOut, 0);
        vm.stopPrank();

        uint256 balanceEth = zap.balanceOfBaseAsset(receiver);
        assertGt(balanceEth, 0, "Balance should be > 0");
    }

    function test_BalanceOfStETH() public {
        uint256 ethAmount = 1 ether;
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);

        vm.startPrank(user1);
        zap.zapNativeAsset{value: ethAmount}(receiver, minWstEthOut, 0);
        vm.stopPrank();

        uint256 balanceStEth = zap.balanceOfCollateral(receiver);
        assertGt(balanceStEth, 0, "Balance should be > 0");
    }

    function test_TotalValueETH() public {
        uint256 ethAmount1 = 1 ether;
        uint256 ethAmount2 = 2 ether;

        vm.startPrank(user1);
        uint256 minWstEthOut1 = _calculateMinWstEthFromEth(ethAmount1);
        uint256 minWstEthOut2 = _calculateMinWstEthFromEth(ethAmount2);

        zap.zapNativeAsset{value: ethAmount1}(receiver, minWstEthOut1, 0);
        zap.zapNativeAsset{value: ethAmount2}(receiver, minWstEthOut2, 0);
        vm.stopPrank();

        uint256 totalValue = zap.totalValueBaseAsset();

        assertGt(totalValue, 0, "Total value should be > 0");
        assertGe(totalValue, ((ethAmount1 + ethAmount2) * 90) / 100, "Total value should be reasonable");
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new GenesisETHZap_v1(genesis));

        // Upgrade proxy
        vm.prank(zapOwner);
        zap.upgradeToAndCall(newImpl, "");

        // Verify upgrade worked
        assertEq(UnsafeUpgrades.getImplementationAddress(address(zap)), newImpl, "Implementation should be upgraded");

        // Verify functionality still works
        uint256 ethAmount = 1 ether;
        uint256 minWstEthOut = _calculateMinWstEthFromEth(ethAmount);
        vm.startPrank(user1);
        uint256 sharesOut = zap.zapNativeAsset{value: ethAmount}(receiver, minWstEthOut, 0);
        vm.stopPrank();

        assertGt(sharesOut, 0, "Should still work after upgrade");
    }

    function test_Upgrade_OnlyOwner() public {
        address newImpl = address(new GenesisETHZap_v1(genesis));

        vm.prank(user1);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
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

    // ============ Constructor Guard Tests ============

    function test_Constructor_ZeroGenesis() public {
        // The zap refuses to be built against a zero Genesis address.
        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        new GenesisETHZap_v1(address(0));
    }

    function test_Constructor_WrappedCollateralMismatch() public {
        // The zap refuses to be built against a Genesis whose wrapped collateral token differs from
        // the wstETH the zap's network config is compiled for.
        address wrongGenesis = address(new MockWrongTokenGenesis());
        vm.expectRevert(abi.encodeWithSelector(IZapErrors.WrappedCollateralMismatch.selector, address(0xBEEF), WSTETH));
        new GenesisETHZap_v1(wrongGenesis);
    }

    // ============ Negative Path Tests ============

    function test_ZapEth_ZeroAmount() public {
        // Zapping with no ETH attached must fail closed instead of running the conversion with 0.
        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapNativeAsset{value: 0}(receiver, 0, 0);
        vm.stopPrank();
    }

    function test_ZapEth_ZeroReceiver() public {
        // Genesis shares must never be minted to the zero address.
        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        zap.zapNativeAsset{value: 1 ether}(address(0), 0, 0);
        vm.stopPrank();
    }

    function test_ZapEth_SlippageWrappedCollateral() public {
        // An unsatisfiable wrapped-collateral min-out makes the zap revert rather than deposit less
        // than the user demanded. The `received` argument derives from the live Lido share rate, so
        // only the selector is pinned.
        vm.startPrank(user1);
        vm.expectPartialRevert(IZapErrors.SlippageTooHighWrappedCollateral.selector);
        zap.zapNativeAsset{value: 1 ether}(receiver, type(uint256).max, 0);
        vm.stopPrank();
    }

    function test_ZapEth_SlippageBaseAssetValue() public {
        // The independent ETH-equivalent value bound is enforced after the wrapped-collateral bound;
        // an unsatisfiable value floor reverts even when the wrapped min-out passes.
        vm.startPrank(user1);
        vm.expectPartialRevert(IZapErrors.SlippageTooHighBaseAssetValue.selector);
        zap.zapNativeAsset{value: 1 ether}(receiver, 0, type(uint256).max);
        vm.stopPrank();
    }

    function test_ZapStEth_ZeroAmount() public {
        // A zero collateral amount is rejected before any token pull happens.
        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAmount.selector);
        zap.zapCollateral(0, 0, receiver);
        vm.stopPrank();
    }

    function test_ZapStEth_ZeroReceiver() public {
        // The receiver guard fires before the stETH pull, so no funds move.
        vm.startPrank(user1);
        vm.expectRevert(IZapErrors.ZeroAddress.selector);
        zap.zapCollateral(1 ether, 0, address(0));
        vm.stopPrank();
    }

    function test_ZapStEth_SlippageWrappedCollateral() public {
        // An unsatisfiable min-out on the stETH path reverts after the pull+wrap, undoing the zap.
        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 5 ether}(address(0));
        uint256 stEthAmount = IERC20(STETH).balanceOf(user1);
        IERC20(STETH).approve(address(zap), stEthAmount);

        vm.expectPartialRevert(IZapErrors.SlippageTooHighWrappedCollateral.selector);
        zap.zapCollateral(stEthAmount, type(uint256).max, receiver);
        vm.stopPrank();
    }

    function test_DepositToGenesis_MintMismatch() public {
        // Genesis must credit shares exactly 1:1 with the wrapped collateral deposited; a Genesis
        // that credits less must make the zap revert with MintMismatchExpected instead of silently
        // shorting the receiver. The mismatch amounts derive from the live Lido wrap, so only the
        // selector is pinned.
        address shortGenesis = address(new MockShortMintGenesis(WSTETH));
        address mismatchZapImpl = address(new GenesisETHZap_v1(shortGenesis));
        address mismatchZapProxy = UnsafeUpgrades.deployUUPSProxy(
            mismatchZapImpl,
            abi.encodeCall(GenesisETHZap_v1.initialize, (address(this), zapOwner))
        );

        vm.deal(user1, 10 ether);
        vm.startPrank(user1);
        ISTETHV2(STETH).submit{value: 5 ether}(address(0));
        uint256 stEthAmount = IERC20(STETH).balanceOf(user1);
        IERC20(STETH).approve(mismatchZapProxy, stEthAmount);

        vm.expectPartialRevert(IZapErrors.MintMismatchExpected.selector);
        GenesisETHZap_v1(payable(mismatchZapProxy)).zapCollateral(stEthAmount, 0, receiver);
        vm.stopPrank();
    }

    function test_Fallback_FunctionNotFound() public {
        // Calls to unknown selectors revert with FunctionNotFound instead of silently succeeding.
        vm.expectRevert(IZapErrors.FunctionNotFound.selector);
        ITriggerZapFallback(address(zap)).__zapFallbackProbe();
    }
}
