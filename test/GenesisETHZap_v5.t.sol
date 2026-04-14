// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {GenesisETHZap_v5} from "src/zap/upgradeable/GenesisETHZap_v5.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

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

contract GenesisETHZapV5ForkTest is TestMinterSetUp {
    GenesisETHZap_v5 zap;
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

        // Deploy Genesis
        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        // Deploy upgradeable zap
        zapOwner = makeAddr("zapOwner");
        zapImpl = address(new GenesisETHZap_v5(genesis));
        zapProxy = UnsafeUpgrades.deployUUPSProxy(
            zapImpl, abi.encodeCall(GenesisETHZap_v5.initialize, (address(this), zapOwner))
        );
        zap = GenesisETHZap_v5(payable(zapProxy));
        vm.label(address(zap), "GenesisETHZapV5");

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

        uint256 sharesOut = zap.zapNativeAsset{value: ethAmount}(receiver, minWstEthOut, 0);

        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(genesis);

        console.log("=== ETH Zap v4 Success ===");
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
        string memory expectedName =
            string(abi.encodePacked("Genesis zap ", IERC20Metadata(IGenesis(genesis).PEGGED_TOKEN()).name()));
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
        (uint256 previewShares,) = zap.previewSharesFromBase(ethAmount);

        assertGt(previewShares, 0, "Preview should return > 0");
        // Should match previewWrappedCollateralFromBase since Genesis uses 1:1 mapping
        assertEq(previewShares, zap.previewWrappedCollateralFromBase(ethAmount), "Should match wstETH preview");
    }

    function test_PreviewGenesisFromStEth() public view {
        uint256 stEthAmount = 1 ether;
        (uint256 previewShares,) = zap.previewSharesFromCollateral(stEthAmount);

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
        assertGe(totalValue, (ethAmount1 + ethAmount2) * 90 / 100, "Total value should be reasonable");
    }

    // ============ Upgrade Tests ============

    function test_Upgrade() public {
        // Deploy new implementation
        address newImpl = address(new GenesisETHZap_v5(genesis));

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
        address newImpl = address(new GenesisETHZap_v5(genesis));

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

