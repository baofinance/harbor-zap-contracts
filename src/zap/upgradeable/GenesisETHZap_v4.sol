// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {ISTETHV2, IStETH} from "src/interfaces/IStETH.sol";
import {IWstETHWrapV2, IWstETH} from "src/interfaces/IWstETH.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title GenesisETHZap V4
/// @notice One-click zapper: ETH or stETH → wstETH → Genesis vault
/// @dev Uses correct share-based conversion (critical for 2025+ stETH ratio)
/// @dev Includes slippage protection, accurate previews, and real-time value tracking
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Finance
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract GenesisETHZap_v4 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
    using SafeERC20 for IERC20;

    // ========== Constants ==========
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant DEFAULT_REFERRAL = 0x3dFc49e5112005179Da613BdE5973229082dAc35;

    // ========== Immutables ==========
    address public immutable GENESIS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IStETH public immutable stETH;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IWstETH public immutable wstETH;

    // ========== Configurable ==========
    address public referral;

    // ========== Events ==========
    /// @notice Emitted when ETH is successfully zapped into Genesis
    event ZappedETH(
        address indexed user,
        address indexed receiver,
        uint256 ethIn,
        uint256 genesisSharesOut,
        uint256 ethValueNow,
        uint256 stEthValueNow
    );

    /// @notice Emitted when stETH is successfully zapped into Genesis
    event ZappedStETH(
        address indexed user,
        address indexed receiver,
        uint256 stEthIn,
        uint256 genesisSharesOut,
        uint256 ethValueNow,
        uint256 stEthValueNow
    );

    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wstETH as collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();

        if (genesis_ == address(0)) revert ZeroAddress();

        GENESIS = genesis_;
        stETH = IStETH(STETH);
        wstETH = IWstETH(WSTETH);
    }

    // ========== Initialization ==========
    /// @notice Initialize the contract
    /// @param owner_ Address that will own the contract
    /// @param referral_ Optional Lido referral (use address(0) for default)
    function initialize(address owner_, address referral_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();

        address initialReferral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;
        referral = initialReferral;
        emit ReferralUpdated(address(0), initialReferral);
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    // =================================================================
    // ====================== USER FACING ZAPS =========================
    // =================================================================

    /// @notice Zap ETH → stETH → wstETH → Genesis in one transaction
    /// @dev Includes slippage protection against front-running/MEV
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWstEthOut Minimum acceptable wstETH (use preview for 0.1-0.5% buffer)
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapEth(
        address receiver,
        uint256 minWstEthOut
    ) external payable nonReentrant returns (uint256 sharesOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 ethIn = msg.value;

        // 1. ETH → stETH via Lido (never trust return value)
        uint256 stEthBefore = IERC20(STETH).balanceOf(address(this));
        ISTETHV2(STETH).submit{value: ethIn}(referral);
        uint256 stEthReceived = IERC20(STETH).balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert NoStETHReceived();

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        sharesOut = IWstETHWrapV2(WSTETH).wrap(stEthReceived);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != sharesOut) {
            // Use actual balance if different (shouldn't happen, but be safe)
            sharesOut = wstEthReceived;
        }

        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert SlippageTooHigh();

        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);

        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stEthNow) = _getCurrentValues(sharesOut);
        emit ZappedETH(_msgSender(), receiver, ethIn, sharesOut, ethNow, stEthNow);

        // Clean up
        IERC20(STETH).forceApprove(WSTETH, 0);
    }

    /// @notice Zap existing stETH → wstETH → Genesis
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWstEthOut Minimum acceptable wstETH out
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapStEth(
        uint256 stEthAmount,
        address receiver,
        uint256 minWstEthOut
    ) external nonReentrant returns (uint256 sharesOut) {
        if (stEthAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // 1. Transfer stETH from user
        IERC20(STETH).safeTransferFrom(_msgSender(), address(this), stEthAmount);

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthAmount);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        sharesOut = IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != sharesOut) {
            // Use actual balance if different (shouldn't happen, but be safe)
            sharesOut = wstEthReceived;
        }

        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert SlippageTooHigh();

        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);

        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stEthNow) = _getCurrentValues(sharesOut);
        emit ZappedStETH(_msgSender(), receiver, stEthAmount, sharesOut, ethNow, stEthNow);

        // Clean up
        IERC20(STETH).forceApprove(WSTETH, 0);
    }

    // =================================================================
    // ====================== INTERNAL HELPERS =========================
    // =================================================================

    function _depositToGenesis(uint256 amount, address receiver) internal {
        // Verify contract has sufficient balance before deposit
        uint256 balanceBefore = IERC20(WSTETH).balanceOf(address(this));
        if (balanceBefore < amount) revert NoStETHReceived();
        
        // Double-check receiver is not zero (defensive)
        if (receiver == address(0)) revert ZeroAddress();
        
        // Check receiver's Genesis balance before deposit
        uint256 sharesBefore = IGenesis(GENESIS).balanceOf(receiver);
        
        // wstETH uses standard ERC20 approve (returns bool)
        // Reset approval first if needed (some tokens require reset before new approval)
        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), GENESIS);
        if (currentAllowance > 0) {
            // Reset to 0 first
            IERC20(WSTETH).approve(GENESIS, 0);
        }
        // Approve the amount (wstETH approve returns bool, but we don't need to check it)
        IERC20(WSTETH).approve(GENESIS, amount);
        
        // Genesis deposit function pulls tokens via safeTransferFrom
        // Try interface call directly - should work with proper approval
        IGenesis(GENESIS).deposit(amount, receiver);
        
        // Validate that shares were actually minted
        uint256 sharesAfter = IGenesis(GENESIS).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != amount) {
            revert DepositFailed();
        }
        
        // Reset approval after successful deposit
        IERC20(WSTETH).approve(GENESIS, 0);
    }

    /// @dev Returns real-time redeemable values for any wstETH amount
    function _getCurrentValues(uint256 wstEthAmount) internal view returns (uint256 ethValue, uint256 stEthValue) {
        stEthValue = wstETH.getStETHByWstETH(wstEthAmount);
        ethValue = stETH.getPooledEthByShares(stEthValue);
    }

    // =================================================================
    // ====================== VIEW FUNCTIONS (FRONTEND) ===============
    // =================================================================

    /// @notice Real-time user balance in growing ETH terms (primary display value)
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfETH(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        if (shares == 0) return 0;
        (uint256 eth,) = _getCurrentValues(shares);
        return eth;
    }

    /// @notice Real-time user balance in stETH terms
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfStETH(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        return shares == 0 ? 0 : wstETH.getStETHByWstETH(shares);
    }

    /// @notice Total vault value in real ETH (grows daily)
    // forge-lint: disable-next-line(mixed-case-function)
    function totalValueETH() external view returns (uint256) {
        uint256 totalWstEth = IERC20(WSTETH).balanceOf(GENESIS);
        if (totalWstEth == 0) return 0;
        (uint256 eth,) = _getCurrentValues(totalWstEth);
        return eth;
    }

    // =================================================================
    // ====================== PREVIEW FUNCTIONS =======================
    // =================================================================

    /// @notice Preview the expected wstETH output from an ETH amount
    /// @param ethAmount Amount of ETH
    /// @return wstEthAmount Expected wstETH amount (which equals Genesis shares)
    function previewWstEthFromEth(uint256 ethAmount) external view returns (uint256 wstEthAmount) {
        // Calculate stETH shares that will be minted for this ETH amount
        uint256 stEthShares = IStETH(STETH).getSharesByPooledEth(ethAmount);
        // Convert shares back to stETH token amount (accounts for rounding)
        uint256 stEthAmount = IStETH(STETH).getPooledEthByShares(stEthShares);
        // Convert stETH to wstETH
        wstEthAmount = IWstETH(WSTETH).getWstETHByStETH(stEthAmount);
    }

    /// @notice Preview the expected wstETH output from a stETH amount
    /// @param stEthAmount Amount of stETH
    /// @return wstEthAmount Expected wstETH amount (which equals Genesis shares)
    function previewWstEthFromStEth(uint256 stEthAmount) external view returns (uint256 wstEthAmount) {
        wstEthAmount = IWstETH(WSTETH).getWstETHByStETH(stEthAmount);
    }

    /// @notice Preview the expected Genesis shares from an ETH amount
    /// @dev Genesis uses 1:1 deposits, so wstETH amount equals shares
    /// @param ethAmount Amount of ETH
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewGenesisFromEth(uint256 ethAmount) external view returns (uint256 sharesOut, uint256 wstEthAmount) {
        wstEthAmount = this.previewWstEthFromEth(ethAmount);
        sharesOut = wstEthAmount; // 1:1 mapping
    }

    /// @notice Preview the expected Genesis shares from a stETH amount
    /// @dev Genesis uses 1:1 deposits, so wstETH amount equals shares
    /// @param stEthAmount Amount of stETH
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewGenesisFromStEth(uint256 stEthAmount) external view returns (uint256 sharesOut, uint256 wstEthAmount) {
        wstEthAmount = this.previewWstEthFromStEth(stEthAmount);
        sharesOut = wstEthAmount; // 1:1 mapping
    }

    // =================================================================
    // ====================== OWNER FUNCTIONS ==========================
    // =================================================================

    /// @notice Update Lido referral address
    function setReferral(address newReferral) external onlyOwner {
        emit ReferralUpdated(referral, newReferral);
        referral = newReferral;
    }

    /// @notice Rescue stuck ETH
    // forge-lint: disable-next-line(mixed-case-function)
    function rescueETH() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /// @notice Rescue any ERC20 (except stETH/wstETH which should never be stuck)
    function rescueToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // =================================================================
    // ====================== RECEIVE ETH ==============================
    // =================================================================
    receive() external payable {}

    fallback() external payable {
        revert FunctionNotFound();
    }
}

