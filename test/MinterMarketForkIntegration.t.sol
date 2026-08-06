// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MinterETHZap_v1} from "@harborzap/zap/upgradeable/MinterETHZap_v1.sol";
import {MinterUSDCZap_v1} from "@harborzap/zap/upgradeable/MinterUSDCZap_v1.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {ForkConstants} from "@harborzap-test/ForkConstants.sol";

interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

interface IWstETHWrapV2 {
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice Shared setup: pinned mainnet fork, load market from zap-addresses.json, deploy v1 zaps on production minters.
abstract contract MinterMarketForkBase is Test {
    using stdJson for string;

    string internal constant ZAP_CONFIG_PATH = "deployments/mainnet/zap-addresses.json";

    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant SLIPPAGE_BPS = 200; // 2% buffer on previews

    address internal minterEth;
    address internal minterUsdc;
    address[] internal stabilityPools;
    address internal peggedToken;

    address internal user;
    uint256 internal userPk;
    address internal receiver;
    address internal zapOwner;

    MinterETHZap_v1 internal ethZap;
    MinterUSDCZap_v1 internal usdcZap;

    function _marketKey() internal pure virtual returns (string memory);

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), ForkConstants.MAINNET_FORK_BLOCK);

        userPk = 0xA11CE;
        user = vm.addr(userPk);
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
        address ethImpl = address(new MinterETHZap_v1(minterEth));
        address ethProxy = UnsafeUpgrades.deployUUPSProxy(
            ethImpl, abi.encodeCall(MinterETHZap_v1.initialize, (address(this), zapOwner))
        );
        ethZap = MinterETHZap_v1(payable(ethProxy));
        vm.label(address(ethZap), "MinterETHZap_v1_integration");

        address usdcImpl = address(new MinterUSDCZap_v1(minterUsdc));
        address usdcProxy = UnsafeUpgrades.deployUUPSProxy(
            usdcImpl, abi.encodeCall(MinterUSDCZap_v1.initialize, (address(this), zapOwner))
        );
        usdcZap = MinterUSDCZap_v1(payable(usdcProxy));
        vm.label(address(usdcZap), "MinterUSDCZap_v1_integration");

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            ethZap.setStabilityPoolAllowed(stabilityPools[i], true);
            usdcZap.setStabilityPoolAllowed(stabilityPools[i], true);
        }
    }

    function _minOut(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return amount - ((amount * SLIPPAGE_BPS) / 10_000);
    }

    /// @dev stETH uses Lido share accounting; fund via submit instead of deal().
    function _fundUserWithStEth(uint256 ethAmount) internal returns (uint256 stEthBalance) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        ISTETHV2(STETH).submit{value: ethAmount}(address(0));
        stEthBalance = IERC20(STETH).balanceOf(user);
        assertGt(stEthBalance, 0, "stETH submit failed");
    }

    function _fundUserWithWstEth(uint256 ethAmount) internal returns (uint256 wstEthAmount) {
        uint256 stEthAmount = _fundUserWithStEth(ethAmount);
        vm.startPrank(user);
        IERC20(STETH).approve(WSTETH, stEthAmount);
        wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        vm.stopPrank();
        assertGt(wstEthAmount, 0, "wstETH wrap failed");
    }
}

/// @notice Integration fork tests: production BTC minters + real stability pools, v1 zaps on both rails.
contract MinterBtcMarketForkIntegrationTest is MinterMarketForkBase {
    function _marketKey() internal pure override returns (string memory) {
        return "BTC";
    }

    function test_BTC_PeggedTokenIsHaBtcFamily() public view {
        string memory symbol = IERC20Metadata(peggedToken).symbol();
        assertTrue(_containsIgnoreCase(symbol, "BTC"), "expected BTC pegged symbol");
    }

    function test_BTC_EthRail_ZapNativeToPegged_Success() public {
        uint256 ethAmount = 0.05 ether;
        (uint256 previewPegged, uint256 previewWrapped) = ethZap.previewPeggedFromBase(ethAmount);
        uint256 peggedBefore = IERC20(peggedToken).balanceOf(receiver);

        vm.deal(user, ethAmount);
        vm.prank(user);
        uint256 peggedOut =
            ethZap.zapNativeAssetToPegged{value: ethAmount}(_minOut(previewWrapped), receiver, _minOut(previewPegged));

        assertGt(peggedOut, 0, "peggedOut");
        assertEq(IERC20(peggedToken).balanceOf(receiver), peggedBefore + peggedOut, "receiver pegged");
        // Lido share rounding can leave at most 1 wei stETH; wrapped must be fully consumed.
        assertLe(IERC20(STETH).balanceOf(address(ethZap)), 1, "at most 1 wei stETH dust in zap");
        assertEq(IERC20(WSTETH).balanceOf(address(ethZap)), 0, "no wstETH left in zap");
        assertApproxEqRel(peggedOut, previewPegged, 0.02e18, "preview within 2%");
    }

    function test_BTC_EthRail_ZapNativeToPegged_MinPeggedOutReverts() public {
        uint256 ethAmount = 0.04 ether;
        (uint256 previewPegged, uint256 previewWrapped) = ethZap.previewPeggedFromBase(ethAmount);

        vm.deal(user, ethAmount);
        vm.prank(user);
        // Harbor minter: MintInsufficientAmount(token, amount, minAmount)
        vm.expectPartialRevert(bytes4(keccak256("MintInsufficientAmount(address,uint256,uint256)")));
        ethZap.zapNativeAssetToPegged{value: ethAmount}(_minOut(previewWrapped), receiver, previewPegged * 2);
    }

    function test_BTC_EthRail_ZapNativeToEachStabilityPool() public {
        uint256 ethAmount = 0.05 ether;

        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            (uint256 previewPegged, uint256 previewWrapped) = ethZap.previewStabilityPoolFromBase(ethAmount);
            vm.deal(user, ethAmount);

            vm.prank(user);
            (uint256 peggedOut, uint256 deposited) = ethZap.zapNativeAssetToStabilityPool{value: ethAmount}(
                _minOut(previewWrapped),
                receiver,
                _minOut(previewPegged),
                pool,
                _minOut(previewPegged)
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
                stEthAmount,
                _minOut(previewWrapped),
                receiver,
                _minOut(previewPegged),
                pool,
                _minOut(previewPegged)
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
        for (uint256 i = 0; i < stabilityPools.length; i++) {
            address pool = stabilityPools[i];
            uint256 wstEthAmount = _fundUserWithWstEth(0.04 ether);
            uint256 previewPegged = ethZap.previewStabilityPoolFromWrappedCollateral(wstEthAmount);

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

    function test_BTC_EthRail_ZapWstEthToStabilityPoolWithPermit_Success() public {
        address pool = stabilityPools[0];
        uint256 wstEthAmount = _fundUserWithWstEth(0.04 ether);
        uint256 previewPegged = ethZap.previewStabilityPoolFromWrappedCollateral(wstEthAmount);

        uint256 nonce = IERC20Permit(WSTETH).nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, user, address(ethZap), wstEthAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(WSTETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.prank(user);
        (uint256 peggedOut, uint256 deposited) = ethZap.zapWrappedCollateralToStabilityPoolWithPermit(
            wstEthAmount, receiver, _minOut(previewPegged), pool, _minOut(previewPegged), deadline, v, r, s
        );

        assertGt(peggedOut, 0, "peggedOut");
        assertEq(deposited, peggedOut, "1:1 deposit");
    }

    function test_BTC_EthRail_ZapWstEthToStabilityPoolWithPermit_FrontRunConsumedNonce_StillSucceeds() public {
        address pool = stabilityPools[0];
        uint256 wstEthAmount = _fundUserWithWstEth(0.04 ether);
        uint256 previewPegged = ethZap.previewStabilityPoolFromWrappedCollateral(wstEthAmount);

        uint256 nonce = IERC20Permit(WSTETH).nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, user, address(ethZap), wstEthAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(WSTETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.prank(user);
        IERC20Permit(WSTETH).permit(user, address(ethZap), wstEthAmount, deadline, v, r, s);

        vm.prank(user);
        (uint256 peggedOut,) = ethZap.zapWrappedCollateralToStabilityPoolWithPermit(
            wstEthAmount, receiver, _minOut(previewPegged), pool, _minOut(previewPegged), deadline, v, r, s
        );
        assertGt(peggedOut, 0, "zap proceeds despite consumed permit nonce");
    }

    function test_BTC_UsdcRail_ZapUsdcToPegged_Success() public {
        uint256 usdcAmount = 50 * 1e6;
        (uint256 previewPegged, uint256 previewWrapped) = usdcZap.previewPeggedFromBase(usdcAmount);
        uint256 peggedBefore = IERC20(peggedToken).balanceOf(receiver);

        deal(USDC, user, usdcAmount);
        vm.startPrank(user);
        IERC20(USDC).approve(address(usdcZap), usdcAmount);
        uint256 peggedOut =
            usdcZap.zapBaseAssetToPegged(usdcAmount, _minOut(previewWrapped), receiver, _minOut(previewPegged));
        vm.stopPrank();

        assertGt(peggedOut, 0, "peggedOut");
        assertEq(IERC20(peggedToken).balanceOf(receiver), peggedBefore + peggedOut, "receiver pegged");
        assertEq(IERC20(USDC).balanceOf(address(usdcZap)), 0, "no USDC left in zap");
        assertEq(IERC20(FXSAVE).balanceOf(address(usdcZap)), 0, "no fxSAVE left in zap");
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
                usdcAmount,
                _minOut(previewWrapped),
                receiver,
                _minOut(previewPegged),
                pool,
                _minOut(previewPegged)
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
                fxUsdAmount,
                _minOut(previewWrapped),
                receiver,
                _minOut(previewPegged),
                pool,
                _minOut(previewPegged)
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

    function test_BTC_UsdcRail_ZapFxSaveToStabilityPoolWithPermit_Success() public {
        address pool = stabilityPools[0];
        uint256 fxSaveAmount = 40 * 1e18;
        deal(FXSAVE, user, fxSaveAmount);
        uint256 previewPegged = usdcZap.previewStabilityPoolFromWrappedCollateral(fxSaveAmount);

        uint256 nonce = IERC20Permit(FXSAVE).nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, user, address(usdcZap), fxSaveAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(FXSAVE).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.prank(user);
        (uint256 peggedOut, uint256 deposited) = usdcZap.zapWrappedCollateralToStabilityPoolWithPermit(
            fxSaveAmount, receiver, _minOut(previewPegged), pool, _minOut(previewPegged), deadline, v, r, s
        );

        assertGt(peggedOut, 0, "peggedOut");
        assertEq(deposited, peggedOut, "1:1 deposit");
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

/// @notice haUSD ETH-rail wiring checks while Genesis is open (public pegged mint is disallowed / zero).
contract MinterHausdEthRailForkIntegrationTest is Test {
    using stdJson for string;

    string internal constant ZAP_CONFIG_PATH = "deployments/mainnet/zap-addresses.json";

    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address internal minterEth;
    address internal peggedToken;
    address internal user;
    address internal receiver;

    MinterETHZap_v1 internal ethZap;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), ForkConstants.MAINNET_FORK_BLOCK);

        user = makeAddr("user");
        receiver = makeAddr("receiver");

        string memory json = vm.readFile(ZAP_CONFIG_PATH);
        minterEth = json.readAddress(".markets.USD.addresses.minterEth");
        assertGt(minterEth.code.length, 0, "haUSD minterEth not deployed");
        peggedToken = IMinter(minterEth).PEGGED_TOKEN();
        assertEq(keccak256(bytes(IERC20Metadata(peggedToken).symbol())), keccak256("haUSD"), "expected haUSD");
        assertEq(IMinter(minterEth).WRAPPED_COLLATERAL_TOKEN(), WSTETH, "expected wstETH");

        address ethImpl = address(new MinterETHZap_v1(minterEth));
        address ethProxy = UnsafeUpgrades.deployUUPSProxy(
            ethImpl, abi.encodeCall(MinterETHZap_v1.initialize, (address(this), address(this)))
        );
        ethZap = MinterETHZap_v1(payable(ethProxy));
    }

    function test_USD_EthRail_ZapConstructsAgainstProdMinter() public view {
        assertEq(ethZap.MINTER(), minterEth, "minter wired");
        assertEq(ethZap.WRAPPED_COLLATERAL_ASSET(), WSTETH, "wstETH rail");
    }

    function test_USD_EthRail_ZapNative_SlippageTooHighWrappedCollateral() public {
        // Convert-leg slippage still reverts before the (currently disallowed) pegged mint.
        uint256 ethAmount = 0.03 ether;
        vm.deal(user, ethAmount);
        vm.prank(user);
        vm.expectPartialRevert(IZapErrors.SlippageTooHighWrappedCollateral.selector);
        ethZap.zapNativeAssetToPegged{value: ethAmount}(type(uint256).max, receiver, 0);
    }
}
