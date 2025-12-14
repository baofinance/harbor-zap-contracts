// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "src/util/ReentrancyGuard.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @notice Interface for stETH submit function
interface ISTETHV2 {
    function submit(address referral) external payable returns (uint256);
}

/// @notice Interface for wstETH wrap function (not included in IWstETH view-only interface)
interface IWstETHWrapV2 {
    function wrap(uint256 stEthAmount) external returns (uint256);
}

interface IStETH is IERC20 {
    function getPooledEthByShares(uint256 _sharesAmount) external view returns (uint256);
    function getSharesByPooledEth(uint256 _ethAmount) external view returns (uint256);
}

interface IWstETH is IERC20 {
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
}

/// @title MinterETHZapV2
/// @notice One-click zapper for minting pegged or leveraged tokens with ETH or stETH via wstETH
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: ETH → stETH → wstETH → Minter mint
/// @dev Flow: stETH → wstETH → Minter mint
/// @author Harbor Yield Protocol
contract MinterETHZapV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Lido stETH address (mainnet)
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    /// @notice Lido wstETH address (mainnet)
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Default referral address for Lido deposits
    address public constant DEFAULT_REFERRAL = 0x3dFc49e5112005179Da613BdE5973229082dAc35;

    // ============ Immutables ============

    /// @notice Minter contract address
    address public immutable MINTER;

    // ============ Configurable ============

    address public owner;
    address public referral;

    // ============ Events ============

    /// @notice Emitted when ETH is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param ethAmount Amount of ETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param peggedOut Amount of pegged tokens minted
    event ETHZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 ethAmount,
        uint256 wstEthAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when ETH is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param ethAmount Amount of ETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param leveragedOut Amount of leveraged tokens minted
    event ETHZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 ethAmount,
        uint256 wstEthAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when stETH is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param stEthAmount Amount of stETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param peggedOut Amount of pegged tokens minted
    event STETHZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 stEthAmount,
        uint256 wstEthAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when stETH is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param stEthAmount Amount of stETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param leveragedOut Amount of leveraged tokens minted
    event STETHZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 stEthAmount,
        uint256 wstEthAmount,
        uint256 leveragedOut
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);

    // ============ Errors ============

    /// @notice Thrown when zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();

    /// @notice Thrown when wstETH address doesn't match Minter wrapped collateral token
    error WstETHMismatch(address expected, address provided);

    error Unauthorized();
    error FunctionNotFound();
    error NoStETHReceived();
    error SlippageTooHigh();

    // ============ Constructor ============

    /// @notice Constructor sets the Minter address
    /// @param minter_ Address of the Minter contract (must accept wstETH as wrapped collateral)
    /// @param referral_ Lido referral address (or address(0))
    constructor(address minter_, address referral_) {
        if (minter_ == address(0)) revert InvalidAddress();

        // Verify that wstETH matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (WSTETH != expectedCollateral) {
            revert WstETHMismatch(expectedCollateral, WSTETH);
        }

        MINTER = minter_;
        owner = msg.sender;

        address initialReferral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;
        referral = initialReferral;

        emit OwnershipTransferred(address(0), msg.sender);
        emit ReferralUpdated(address(0), initialReferral);
    }

    // ============ Modifiers ============

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    // ============ External Functions ============

    /// @notice Zap ETH into pegged tokens in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Minter mint pegged
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param minWstEthOut Minimum amount of wstETH to receive (slippage protection)
    /// @return peggedOut Amount of pegged tokens minted
    function zapEthToPegged(
        address receiver,
        uint256 minPeggedOut,
        uint256 minWstEthOut
    ) external payable nonReentrant returns (uint256 peggedOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 ethAmount = msg.value;

        // 1. ETH → stETH via Lido (never trust return value)
        uint256 stEthBefore = IERC20(STETH).balanceOf(address(this));
        ISTETHV2(STETH).submit{value: ethAmount}(referral);
        uint256 stEthReceived = IERC20(STETH).balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert NoStETHReceived();

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthReceived);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != wstEthAmount) {
            // Use actual balance if different
            wstEthAmount = wstEthReceived;
        }
        
        // Slippage protection for wstETH wrapping
        if (wstEthAmount < minWstEthOut) revert SlippageTooHigh();

        // 3. wstETH → Minter mint pegged
        // Verify contract has sufficient balance before minting
        uint256 wstEthBalanceBefore = IERC20(WSTETH).balanceOf(address(this));
        if (wstEthBalanceBefore < wstEthAmount) revert NoStETHReceived();
        
        // Reset approval first if needed
        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), MINTER);
        if (currentAllowance > 0) {
            IERC20(WSTETH).approve(MINTER, 0);
        }
        // Approve the amount
        IERC20(WSTETH).approve(MINTER, wstEthAmount);
        
        peggedOut = IMinter(MINTER).mintPeggedToken(wstEthAmount, receiver, minPeggedOut);
        
        // Verify tokens were actually transferred to Minter
        uint256 wstEthBalanceAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthBalanceDiff = wstEthBalanceBefore - wstEthBalanceAfter;
        
        // Verify the exact amount was transferred
        if (wstEthBalanceDiff != wstEthAmount) {
            revert("Minter mint did not transfer correct amount");
        }

        emit ETHZappedToPegged(msg.sender, MINTER, receiver, ethAmount, wstEthAmount, peggedOut);

        // Reset allowances after interactions
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).approve(MINTER, 0);
    }

    /// @notice Zap ETH into leveraged tokens in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Minter mint leveraged
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param minWstEthOut Minimum amount of wstETH to receive (slippage protection)
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapEthToLeveraged(
        address receiver,
        uint256 minLeveragedOut,
        uint256 minWstEthOut
    ) external payable nonReentrant returns (uint256 leveragedOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 ethAmount = msg.value;

        // 1. ETH → stETH via Lido (never trust return value)
        uint256 stEthBefore = IERC20(STETH).balanceOf(address(this));
        ISTETHV2(STETH).submit{value: ethAmount}(referral);
        uint256 stEthReceived = IERC20(STETH).balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert NoStETHReceived();

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthReceived);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthReceived);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != wstEthAmount) {
            // Use actual balance if different
            wstEthAmount = wstEthReceived;
        }
        
        // Slippage protection for wstETH wrapping
        if (wstEthAmount < minWstEthOut) revert SlippageTooHigh();

        // 3. wstETH → Minter mint leveraged
        // Verify contract has sufficient balance before minting
        uint256 wstEthBalanceBefore = IERC20(WSTETH).balanceOf(address(this));
        if (wstEthBalanceBefore < wstEthAmount) revert NoStETHReceived();
        
        // Reset approval first if needed
        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), MINTER);
        if (currentAllowance > 0) {
            IERC20(WSTETH).approve(MINTER, 0);
        }
        // Approve the amount
        IERC20(WSTETH).approve(MINTER, wstEthAmount);
        
        leveragedOut = IMinter(MINTER).mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);
        
        // Verify tokens were actually transferred to Minter
        uint256 wstEthBalanceAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthBalanceDiff = wstEthBalanceBefore - wstEthBalanceAfter;
        
        // Verify the exact amount was transferred
        if (wstEthBalanceDiff != wstEthAmount) {
            revert("Minter mint did not transfer correct amount");
        }

        emit ETHZappedToLeveraged(msg.sender, MINTER, receiver, ethAmount, wstEthAmount, leveragedOut);

        // Reset allowances after interactions
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).approve(MINTER, 0);
    }

    /// @notice Zap stETH into pegged tokens in one transaction
    /// @dev Flow: stETH → wstETH → Minter mint pegged
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param minWstEthOut Minimum amount of wstETH to receive (slippage protection)
    /// @return peggedOut Amount of pegged tokens minted
    function zapStEthToPegged(
        uint256 stEthAmount,
        address receiver,
        uint256 minPeggedOut,
        uint256 minWstEthOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (stEthAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull stETH from user
        IERC20(STETH).safeTransferFrom(msg.sender, address(this), stEthAmount);

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthAmount);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != wstEthAmount) {
            // Use actual balance if different
            wstEthAmount = wstEthReceived;
        }
        
        // Slippage protection for wstETH wrapping
        if (wstEthAmount < minWstEthOut) revert SlippageTooHigh();

        // 3. wstETH → Minter mint pegged
        // Verify contract has sufficient balance before minting
        uint256 wstEthBalanceBefore = IERC20(WSTETH).balanceOf(address(this));
        if (wstEthBalanceBefore < wstEthAmount) revert NoStETHReceived();
        
        // Reset approval first if needed
        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), MINTER);
        if (currentAllowance > 0) {
            IERC20(WSTETH).approve(MINTER, 0);
        }
        // Approve the amount
        IERC20(WSTETH).approve(MINTER, wstEthAmount);
        
        peggedOut = IMinter(MINTER).mintPeggedToken(wstEthAmount, receiver, minPeggedOut);
        
        // Verify tokens were actually transferred to Minter
        uint256 wstEthBalanceAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthBalanceDiff = wstEthBalanceBefore - wstEthBalanceAfter;
        
        // Verify the exact amount was transferred
        if (wstEthBalanceDiff != wstEthAmount) {
            revert("Minter mint did not transfer correct amount");
        }

        emit STETHZappedToPegged(msg.sender, MINTER, receiver, stEthAmount, wstEthAmount, peggedOut);

        // Reset allowances after interactions
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).approve(MINTER, 0);
    }

    /// @notice Zap stETH into leveraged tokens in one transaction
    /// @dev Flow: stETH → wstETH → Minter mint leveraged
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param minWstEthOut Minimum amount of wstETH to receive (slippage protection)
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapStEthToLeveraged(
        uint256 stEthAmount,
        address receiver,
        uint256 minLeveragedOut,
        uint256 minWstEthOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (stEthAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull stETH from user
        IERC20(STETH).safeTransferFrom(msg.sender, address(this), stEthAmount);

        // 2. stETH → wstETH
        IERC20(STETH).forceApprove(WSTETH, stEthAmount);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthAmount = IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthReceived = wstEthAfter - wstEthBefore;
        
        // Verify we received wstETH
        if (wstEthReceived == 0) revert NoStETHReceived();
        if (wstEthReceived != wstEthAmount) {
            // Use actual balance if different
            wstEthAmount = wstEthReceived;
        }
        
        // Slippage protection for wstETH wrapping
        if (wstEthAmount < minWstEthOut) revert SlippageTooHigh();

        // 3. wstETH → Minter mint leveraged
        // Verify contract has sufficient balance before minting
        uint256 wstEthBalanceBefore = IERC20(WSTETH).balanceOf(address(this));
        if (wstEthBalanceBefore < wstEthAmount) revert NoStETHReceived();
        
        // Reset approval first if needed
        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), MINTER);
        if (currentAllowance > 0) {
            IERC20(WSTETH).approve(MINTER, 0);
        }
        // Approve the amount
        IERC20(WSTETH).approve(MINTER, wstEthAmount);
        
        leveragedOut = IMinter(MINTER).mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);
        
        // Verify tokens were actually transferred to Minter
        uint256 wstEthBalanceAfter = IERC20(WSTETH).balanceOf(address(this));
        uint256 wstEthBalanceDiff = wstEthBalanceBefore - wstEthBalanceAfter;
        
        // Verify the exact amount was transferred
        if (wstEthBalanceDiff != wstEthAmount) {
            revert("Minter mint did not transfer correct amount");
        }

        emit STETHZappedToLeveraged(msg.sender, MINTER, receiver, stEthAmount, wstEthAmount, leveragedOut);

        // Reset allowances after interactions
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).approve(MINTER, 0);
    }

    // ============ View Functions (Preview) ============

    /// @notice Preview expected wstETH output for a given ETH input
    /// @dev Note: This is an approximation. Actual output may vary slightly due to stETH rebasing
    /// @param ethIn Amount of ETH to zap
    /// @return expectedWstEthOut Expected wstETH amount (for slippage calculation)
    function previewZapEth(uint256 ethIn) external view returns (uint256 expectedWstEthOut) {
        IStETH stETH = IStETH(STETH);
        IWstETH wstETH = IWstETH(WSTETH);
        
        // 1. ETH → stETH: Convert ETH to stETH shares, then back to stETH tokens
        uint256 stEthShares = stETH.getSharesByPooledEth(ethIn);
        uint256 expectedStEth = stETH.getPooledEthByShares(stEthShares);
        // 2. stETH → wstETH
        expectedWstEthOut = wstETH.getWstETHByStETH(expectedStEth);
    }

    /// @notice Preview expected wstETH output for a given stETH input
    /// @param stEthIn Amount of stETH to zap
    /// @return expectedWstEthOut Expected wstETH amount (for slippage calculation)
    function previewZapStEth(uint256 stEthIn) external view returns (uint256 expectedWstEthOut) {
        IWstETH wstETH = IWstETH(WSTETH);
        // stETH → wstETH
        expectedWstEthOut = wstETH.getWstETHByStETH(stEthIn);
    }

    /// @notice Preview expected pegged tokens for a given wstETH input
    /// @param wstEthAmount Amount of wstETH to mint with
    /// @return expectedPeggedOut Expected pegged tokens (for slippage calculation)
    function previewMintPegged(uint256 wstEthAmount) external view returns (uint256 expectedPeggedOut) {
        (,,,expectedPeggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview expected leveraged tokens for a given wstETH input
    /// @param wstEthAmount Amount of wstETH to mint with
    /// @return expectedLeveragedOut Expected leveraged tokens (for slippage calculation)
    function previewMintLeveraged(uint256 wstEthAmount) external view returns (uint256 expectedLeveragedOut) {
        (,,,uint256 collateralUsed,expectedLeveragedOut,,) = IMinter(MINTER).mintLeveragedTokenDryRun(wstEthAmount);
    }

    // ============ Owner Functions ============

    function setReferral(address newReferral) external onlyOwner {
        emit ReferralUpdated(referral, newReferral);
        referral = newReferral;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function rescueEth() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    // ============ Safety Functions ============

    receive() external payable {
        // Allow receiving ETH for zapEthToPegged() and zapEthToLeveraged() functions
    }

    fallback() external payable {
        revert FunctionNotFound();
    }
}

