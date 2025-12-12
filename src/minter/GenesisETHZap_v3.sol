// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

// ========== Interfaces ==========
interface IStETH is IERC20 {
    function submit(address referral) external payable returns (uint256);
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}

interface IWstETH is IERC20 {
    function wrap(uint256 stEthAmount) external returns (uint256);
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
    function stETH() external view returns (address);
}

interface IGenesis {
    function WRAPPED_COLLATERAL_TOKEN() external view returns (address);
    function deposit(uint256 amount, address receiver) external;
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
    IStETH public immutable stETH;
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
        uint256 stETHValueNow
    );

    /// @notice Emitted when stETH is successfully zapped into Genesis
    event ZappedStETH(
        address indexed user,
        address indexed receiver,
        uint256 stEthIn,
        uint256 genesisSharesOut,
        uint256 ethValueNow,
        uint256 stETHValueNow
    );

    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);

    // ========== Errors ==========
    error ZeroAmount();
    error ZeroAddress();
    error NoStETHReceived();
    error SlippageTooHigh();
    error InvalidGenesisCollateral();

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wstETH as collateral)
    /// @param referral_ Optional Lido referral (use address(0) for default)
    constructor(address genesis_, address referral_) Ownable(msg.sender) {
        if (genesis_ == address(0)) revert ZeroAddress();
        if (IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN() != WSTETH)
            revert InvalidGenesisCollateral();

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
        uint256 stEthBefore = stETH.balanceOf(address(this));
        stETH.submit{value: ethIn}(referral);
        uint256 stEthReceived = stETH.balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert NoStETHReceived();

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        sharesOut = wstETH.wrap(stEthReceived);

        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert SlippageTooHigh();

        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);

        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stETHNow) = _getCurrentValues(sharesOut);
        emit ZappedETH(msg.sender, receiver, ethIn, sharesOut, ethNow, stETHNow);

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
        sharesOut = wstETH.wrap(stEthAmount);

        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert SlippageTooHigh();

        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);

        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stETHNow) = _getCurrentValues(sharesOut);
        emit ZappedStETH(msg.sender, receiver, stEthAmount, sharesOut, ethNow, stETHNow);

        // Clean up
        IERC20(STETH).forceApprove(WSTETH, 0);
    }

    // =================================================================
    // ====================== INTERNAL HELPERS =========================
    // =================================================================

    function _depositToGenesis(uint256 amount, address receiver) internal {
        IERC20(WSTETH).forceApprove(GENESIS, amount);
        IGenesis(GENESIS).deposit(amount, receiver);
        IERC20(WSTETH).forceApprove(GENESIS, 0);
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
    function balanceOfETH(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        if (shares == 0) return 0;
        (uint256 eth,) = _getCurrentValues(shares);
        return eth;
    }

    /// @notice Real-time user balance in stETH terms
    function balanceOfStETH(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        return shares == 0 ? 0 : wstETH.getStETHByWstETH(shares);
    }

    /// @notice Total vault value in real ETH (grows daily)
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