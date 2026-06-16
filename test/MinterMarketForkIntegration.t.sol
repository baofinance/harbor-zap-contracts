// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MinterETHZap_v4} from "src/zap/upgradeable/MinterETHZap_v4.sol";
import {MinterUSDCZap_v4} from "src/zap/upgradeable/MinterUSDCZap_v4.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

/// @notice Shared setup: fork mainnet, load market from zap-addresses.json, deploy v4 zaps wired to production minters.
abstract contract MinterMarketForkBase is Test {
    using stdJson for string;

    string internal constant ZAP_CONFIG_PATH = "deployments/mainnet/zap-addresses.json";

    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    uint256 internal constant SLIPPAGE_BPS = 200; // 2% buffer on previews

    address internal minterEth;
    address internal minterUsdc;
    address[] internal stabilityPools;
    address internal peggedToken;

    address internal user;
    address internal receiver;
    address internal zapOwner;

    MinterETHZap_v4 internal ethZap;
    MinterUSDCZap_v4 internal usdcZap;

    function _marketKey() internal pure virtual returns (string memory);

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        user = makeAddr("user");
        receiver = makeAddr("receiver");
        zapOwner = address(this);

        _loadMarketConfig();
        _deployZaps();
    }

    function _loadMarketConfig() internal {
        string memory json = vm.readFile(ZAP_CONFIG_PATH);
        string memory marketPath = string.concat(".markets.", _marketKey());

        minterEth = json.readAddress(string.concat(marketPath, ".addresses.minterEth"));
        minterUsdc = json.readAddress(string.concat(marketPath, ".addresses.minterUsdc"));
        stabilityPools = json.readAddressArray(string.concat(marketPath, ".stabilityPools"));

        assertGt(minterEth.code.length, 0, "minterEth not deployed");
        assertGt(minterUsdc.code.length, 0, "minterUsdc not deployed");
        assertGt(stabilityPools.length, 0, "no stability pools in config");

        peggedToken = IMinter(minterEth).PEGGED_TOKEN();
        assertEq(peggedToken, IMinter(minterUsdc).PEGGED_TOKEN(), "ETH/USDC minters pegged token mismatch");

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            assertGt(pool.code.length, 0, "stability pool not deployed");
            assertEq(IStabilityPool(pool).ASSET_TOKEN(), peggedToken, "pool ASSET_TOKEN mismatch");
        }
    }

    function _deployZaps() internal {
        address ethImpl = address(new MinterETHZap_v4(minterEth));
        address ethProxy = UnsafeUpgrades.deployUUPSProxy(
            ethImpl, abi.encodeCall(MinterETHZap_v4.initialize, (address(this), zapOwner))
        );
        ethZap = MinterETHZap_v4(payable(ethProxy));
        vm.label(address(ethZap), "MinterETHZap_v4_integration");

        address usdcImpl = address(new MinterUSDCZap_v4(minterUsdc));
        address usdcProxy = UnsafeUpgrades.deployUUPSProxy(
            usdcImpl, abi.encodeCall(MinterUSDCZap_v4.initialize, (address(this), zapOwner))
        );
        usdcZap = MinterUSDCZap_v4(payable(usdcProxy));
        vm.label(address(usdcZap), "MinterUSDCZap_v4_integration");

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            ethZap.setStabilityPoolAllowed(stabilityPools[i], true);
            usdcZap.setStabilityPoolAllowed(stabilityPools[i], true);
        }
    }

    function _minOut(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return amount - (amount * SLIPPAGE_BPS / 10_000);
    }

    /// @dev stETH uses Lido share accounting; fund via submit instead of deal().
    function _fundUserWithStEth(uint256 ethAmount) internal returns (uint256 stEthBalance) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        ISTETHV2(STETH).submit{value: ethAmount}(address(0));
        stEthBalance = IERC20(STETH).balanceOf(user);
        assertGt(stEthBalance, 0, "stETH submit failed");
    }
}

/// @notice Integration fork tests: production BTC minters + real stability pools, v4 zaps on both rails.
contract MinterBtcMarketForkIntegrationTest is MinterMarketForkBase {
    function _marketKey() internal pure override returns (string memory) {
        return "BTC";
    }

    function test_BTC_PeggedTokenIsHaBtcFamily() public view {
        string memory symbol = IERC20Metadata(peggedToken).symbol();
        assertTrue(_containsIgnoreCase(symbol, "BTC"), "expected BTC pegged symbol");
    }

    function test_BTC_EthRail_ZapNativeToEachStabilityPool() public {
        uint256 ethAmount = 0.05 ether;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            (uint256 previewPegged, uint256 previewWrapped) = ethZap.previewStabilityPoolFromBase(ethAmount);
            vm.deal(user, ethAmount);

            vm.prank(user);
            (uint256 peggedOut, uint256 deposited) = ethZap.zapNativeAssetToStabilityPool{value: ethAmount}(
                _minOut(previewWrapped), receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");
        }
    }

    function test_BTC_EthRail_ZapStEthToEachStabilityPool() public {
        uint256 stEthAmount = _fundUserWithStEth(0.06 ether);

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            (uint256 previewPegged, uint256 previewWrapped) = ethZap.previewStabilityPoolFromCollateral(stEthAmount);

            vm.startPrank(user);
            IERC20(STETH).approve(address(ethZap), stEthAmount);
            (uint256 peggedOut, uint256 deposited) = ethZap.zapCollateralToStabilityPool(
                stEthAmount, _minOut(previewWrapped), receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );
            vm.stopPrank();

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");

            // Re-fund stETH for next pool iteration.
            if (i + 1 < stabilityPools.length) {
                stEthAmount = _fundUserWithStEth(0.06 ether);
            }
        }
    }

    function test_BTC_EthRail_ZapWstEthToEachStabilityPool() public {
        uint256 wstEthAmount = 0.04 ether;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            uint256 previewPegged = ethZap.previewStabilityPoolFromWrappedCollateral(wstEthAmount);
            deal(WSTETH, user, wstEthAmount);

            vm.startPrank(user);
            IERC20(WSTETH).approve(address(ethZap), wstEthAmount);
            (uint256 peggedOut, uint256 deposited) = ethZap.zapWrappedCollateralToStabilityPool(
                wstEthAmount, receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );
            vm.stopPrank();

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");
        }
    }

    function test_BTC_UsdcRail_ZapUsdcToEachStabilityPool() public {
        uint256 usdcAmount = 50 * 1e6;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            (uint256 previewPegged, uint256 previewWrapped) = usdcZap.previewStabilityPoolFromBase(usdcAmount);
            deal(USDC, user, usdcAmount);

            vm.startPrank(user);
            IERC20(USDC).approve(address(usdcZap), usdcAmount);
            (uint256 peggedOut, uint256 deposited) = usdcZap.zapBaseAssetToStabilityPool(
                usdcAmount, _minOut(previewWrapped), receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );
            vm.stopPrank();

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");
        }
    }

    function test_BTC_UsdcRail_ZapFxUsdToEachStabilityPool() public {
        uint256 fxUsdAmount = 50 * 1e18;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            (uint256 previewPegged, uint256 previewWrapped) = usdcZap.previewStabilityPoolFromCollateral(fxUsdAmount);
            deal(FXUSD, user, fxUsdAmount);

            vm.startPrank(user);
            IERC20(FXUSD).approve(address(usdcZap), fxUsdAmount);
            (uint256 peggedOut, uint256 deposited) = usdcZap.zapCollateralToStabilityPool(
                fxUsdAmount, _minOut(previewWrapped), receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );
            vm.stopPrank();

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");
        }
    }

    function test_BTC_UsdcRail_ZapFxSaveToEachStabilityPool() public {
        uint256 fxSaveAmount = 45 * 1e18;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            uint256 previewPegged = usdcZap.previewStabilityPoolFromWrappedCollateral(fxSaveAmount);
            deal(FXSAVE, user, fxSaveAmount);

            vm.startPrank(user);
            IERC20(FXSAVE).approve(address(usdcZap), fxSaveAmount);
            (uint256 peggedOut, uint256 deposited) = usdcZap.zapWrappedCollateralToStabilityPool(
                fxSaveAmount, receiver, _minOut(previewPegged), pool, _minOut(previewPegged)
            );
            vm.stopPrank();

            assertGt(peggedOut, 0, "peggedOut");
            assertGt(deposited, 0, "deposited");
            assertEq(deposited, peggedOut, "pool deposit should match minted pegged");
        }
    }

    function _containsIgnoreCase(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matchAll = true;
            for (uint256 j = 0; j < n.length; j++) {
                uint8 a = uint8(h[i + j]);
                uint8 b = uint8(n[j]);
                if (a >= 65 && a <= 90) a += 32;
                if (b >= 65 && b <= 90) b += 32;
                if (a != b) {
                    matchAll = false;
                    break;
                }
            }
            if (matchAll) return true;
        }
        return false;
    }
}
