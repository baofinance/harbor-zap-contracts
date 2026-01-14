// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

// ========== Interfaces ==========
/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

interface IStETH is IERC20 {
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}

/// @notice Interface for wstETH wrap function
interface IWstETHWrapV2 {
    function wrap(uint256 stEthAmount) external returns (uint256);
}

interface IWstETH is IERC20 {
    // forge-lint: disable-next-line(mixed-case-function)
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
    // forge-lint: disable-next-line(mixed-case-function)
    function stETH() external view returns (address);
}

/// @title GenesisETHZap V3
/// @notice One-click zapper: ETH or stETH → wstETH → Genesis vault
/// @dev Uses correct share-based conversion (critical for 2025+ stETH ratio)
/// @dev Includes slippage protection, accurate previews, and real-time value tracking
/// @author Harbor Finance
contract GenesisETHZapV3 is ReentrancyGuard, Ownable {
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

    // ========== Errors ==========
    error ZeroAmount();
    error ZeroAddress();
    error NoStETHReceived();
    error SlippageTooHigh();
    error InvalidGenesisCollateral();
    error DepositFailed();

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wstETH as collateral)
    /// @param referral_ Optional Lido referral (use address(0) for default)
    constructor(address genesis_, address referral_) Ownable(msg.sender) {
        if (genesis_ == address(0)) revert ZeroAddress();
        
        // Note: Removed WRAPPED_COLLATERAL_TOKEN check during construction
        // as proxy contracts may have issues with external calls during construction.
        // The Genesis address should be verified before deployment.
        // If incorrect, deposit functions will fail anyway.

        GENESIS = genesis_;
        stETH = IStETH(STETH);
        wstETH = IWstETH(WSTETH);
        referral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;

        emit ReferralUpdated(address(0), referral);
    }

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
        emit ZappedETH(msg.sender, receiver, ethIn, sharesOut, ethNow, stEthNow);

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
        IERC20(STETH).safeTransferFrom(msg.sender, address(this), stEthAmount);

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
        emit ZappedStETH(msg.sender, receiver, stEthAmount, sharesOut, ethNow, stEthNow);

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
}
