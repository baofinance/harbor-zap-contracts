// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GenesisETHZap_v1} from "@harborzap/zap/upgradeable/GenesisETHZap_v1.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {ForkConstants} from "@harborzap-test/ForkConstants.sol";

interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

/// @notice Production haUSD Genesis (ETH/stETH/wstETH deposit) + freshly deployed `GenesisETHZap_v1`.
/// @dev Active Genesis: `0x40ff767FF4055D53b1BC1B0141221a37B25905fD` (loaded from zap-addresses.json `USD`).
contract GenesisHausdForkIntegrationTest is Test {
    using stdJson for string;

    string internal constant ZAP_CONFIG_PATH = "deployments/mainnet/zap-addresses.json";

    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );

    uint256 internal constant SLIPPAGE_BPS = 200;

    address internal genesis;
    address internal peggedToken;
    address internal minter;

    address internal user;
    uint256 internal userPk;
    address internal receiver;
    address internal zapOwner;

    GenesisETHZap_v1 internal zap;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), ForkConstants.MAINNET_FORK_BLOCK);

        userPk = 0xA11CE;
        user = vm.addr(userPk);
        receiver = makeAddr("receiver");
        zapOwner = address(this);

        _loadUsdGenesisConfig();
        _deployZap();
    }

    function _loadUsdGenesisConfig() internal {
        string memory json = vm.readFile(ZAP_CONFIG_PATH);
        genesis = json.readAddress(".markets.USD.addresses.genesisEth");
        minter = json.readAddress(".markets.USD.addresses.minterEth");

        assertGt(genesis.code.length, 0, "haUSD genesis not deployed");
        assertGt(minter.code.length, 0, "haUSD minterEth not deployed");
        assertFalse(IGenesis(genesis).genesisIsEnded(), "haUSD genesis already ended");

        peggedToken = IGenesis(genesis).PEGGED_TOKEN();
        assertEq(IGenesis(genesis).MINTER(), minter, "genesis/minter mismatch");
        assertEq(IGenesis(genesis).WRAPPED_COLLATERAL_TOKEN(), WSTETH, "expected wstETH collateral");
        assertEq(keccak256(bytes(IERC20Metadata(peggedToken).symbol())), keccak256("haUSD"), "expected haUSD");
    }

    function _deployZap() internal {
        address impl = address(new GenesisETHZap_v1(genesis));
        address proxy = UnsafeUpgrades.deployUUPSProxy(
            impl,
            abi.encodeCall(GenesisETHZap_v1.initialize, (address(this), zapOwner))
        );
        zap = GenesisETHZap_v1(payable(proxy));
        vm.label(address(zap), "GenesisETHZap_v1_haUSD");
    }

    function _minOut(uint256 amount) internal pure returns (uint256) {
        if (amount == 0) return 0;
        return amount - ((amount * SLIPPAGE_BPS) / 10_000);
    }

    function _fundUserWithStEth(uint256 ethAmount) internal returns (uint256 stEthBalance) {
        vm.deal(user, ethAmount);
        vm.prank(user);
        ISTETHV2(STETH).submit{value: ethAmount}(address(0));
        stEthBalance = IERC20(STETH).balanceOf(user);
        assertGt(stEthBalance, 0, "stETH submit failed");
    }

    function test_USD_Genesis_PeggedIsHaUsd_StillOpen() public view {
        assertEq(IERC20Metadata(peggedToken).symbol(), "haUSD");
        assertFalse(IGenesis(genesis).genesisIsEnded());
    }

    function test_USD_ZapNativeEthToGenesis_Success() public {
        uint256 ethAmount = 0.05 ether;
        (uint256 previewShares, uint256 previewWrapped) = zap.previewSharesFromBase(ethAmount);
        uint256 sharesBefore = IGenesis(genesis).balanceOf(receiver);

        vm.deal(user, ethAmount);
        vm.prank(user);
        uint256 sharesOut = zap.zapNativeAsset{value: ethAmount}(receiver, _minOut(previewWrapped), 0);

        assertGt(sharesOut, 0, "sharesOut");
        assertApproxEqRel(sharesOut, previewShares, 0.02e18, "shares within 2% of preview");
        assertEq(IGenesis(genesis).balanceOf(receiver), sharesBefore + sharesOut, "receiver shares");
        // Lido share rounding can leave at most 1 wei stETH; wrapped must be fully deposited.
        assertLe(IERC20(STETH).balanceOf(address(zap)), 1, "at most 1 wei stETH dust in zap");
        assertEq(IERC20(WSTETH).balanceOf(address(zap)), 0, "no wstETH left in zap");
    }

    function test_USD_ZapStEthToGenesis_Success_AndClearsZapBalances() public {
        uint256 stEthAmount = _fundUserWithStEth(0.06 ether);
        (, uint256 previewWrapped) = zap.previewSharesFromCollateral(stEthAmount);
        uint256 sharesBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 userStEthBefore = IERC20(STETH).balanceOf(user);

        vm.startPrank(user);
        IERC20(STETH).approve(address(zap), stEthAmount);
        uint256 sharesOut = zap.zapCollateral(stEthAmount, _minOut(previewWrapped), receiver);
        vm.stopPrank();

        assertGt(sharesOut, 0, "sharesOut");
        assertEq(IGenesis(genesis).balanceOf(receiver), sharesBefore + sharesOut, "receiver shares");
        assertLe(IERC20(STETH).balanceOf(address(zap)), 1, "at most 1 wei stETH dust in zap");
        assertEq(IERC20(WSTETH).balanceOf(address(zap)), 0, "zap cleared wstETH");
        // User spent the pulled amount (plus any dust refunded back via refundLeftoverAbove).
        assertLe(IERC20(STETH).balanceOf(user), userStEthBefore, "user stETH not increased");
    }

    function test_USD_PreviewSharesFromWrappedCollateral_IsOneToOne() public view {
        uint256 wstEthAmount = 1 ether;
        assertEq(
            zap.previewSharesFromWrappedCollateral(wstEthAmount),
            wstEthAmount,
            "Genesis shares are 1:1 with wrapped"
        );
    }

    function test_USD_ZapNative_SlippageTooHighWrappedCollateral() public {
        uint256 ethAmount = 0.03 ether;
        vm.deal(user, ethAmount);
        vm.prank(user);
        vm.expectPartialRevert(IZapErrors.SlippageTooHighWrappedCollateral.selector);
        zap.zapNativeAsset{value: ethAmount}(receiver, type(uint256).max, 0);
    }

    function test_USD_ZapNative_SlippageTooHighBaseAssetValue() public {
        uint256 ethAmount = 0.03 ether;
        vm.deal(user, ethAmount);
        vm.prank(user);
        vm.expectPartialRevert(IZapErrors.SlippageTooHighBaseAssetValue.selector);
        zap.zapNativeAsset{value: ethAmount}(receiver, 0, type(uint256).max);
    }

    function test_USD_ZapStEthWithPermit_Success() public {
        uint256 stEthAmount = _fundUserWithStEth(0.05 ether);
        (, uint256 previewWrapped) = zap.previewSharesFromCollateral(stEthAmount);

        uint256 nonce = IERC20Permit(STETH).nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, user, address(zap), stEthAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(STETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        uint256 sharesBefore = IGenesis(genesis).balanceOf(receiver);
        vm.prank(user);
        uint256 sharesOut = zap.zapCollateralWithPermit(
            stEthAmount,
            _minOut(previewWrapped),
            receiver,
            deadline,
            v,
            r,
            s
        );

        assertGt(sharesOut, 0, "sharesOut");
        assertEq(IGenesis(genesis).balanceOf(receiver), sharesBefore + sharesOut, "receiver shares");
    }

    function test_USD_ZapStEthWithPermit_FrontRunConsumedNonce_StillSucceeds() public {
        uint256 stEthAmount = _fundUserWithStEth(0.05 ether);
        (, uint256 previewWrapped) = zap.previewSharesFromCollateral(stEthAmount);

        uint256 nonce = IERC20Permit(STETH).nonces(user);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, user, address(zap), stEthAmount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(STETH).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        // Griefing: consume the permit nonce ahead of the zap, but leave a normal allowance.
        vm.prank(user);
        IERC20Permit(STETH).permit(user, address(zap), stEthAmount, deadline, v, r, s);
        assertEq(IERC20(STETH).allowance(user, address(zap)), stEthAmount, "allowance from front-run permit");

        vm.prank(user);
        uint256 sharesOut = zap.zapCollateralWithPermit(
            stEthAmount,
            _minOut(previewWrapped),
            receiver,
            deadline,
            v,
            r,
            s
        );
        assertGt(sharesOut, 0, "zap proceeds despite consumed permit nonce");
    }
}
