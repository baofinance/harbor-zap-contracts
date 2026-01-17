// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {ISTETHV2, IStETH} from "src/interfaces/IStETH.sol";
import {IWstETHWrapV2, IWstETH} from "src/interfaces/IWstETH.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {WstETHConstants} from "src/constants/ethereum/WstETHConstants.sol";

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
    address public constant STETH = WstETHConstants.STETH;
    address public constant WSTETH = WstETHConstants.WSTETH;
    address public constant DEFAULT_REFERRAL = WstETHConstants.DEFAULT_REFERRAL;

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
    event Upgraded(address indexed implementation);

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wstETH as collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();
        if (genesis_ == address(0)) revert IZapErrors.ZeroAddress();

        // Verify that wstETH matches the Genesis wrapped collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (WSTETH != expectedCollateral) {
            revert IZapErrors.CollateralMismatch(expectedCollateral, WSTETH);
        }

        GENESIS = genesis_;
        stETH = IStETH(STETH);
        wstETH = IWstETH(WSTETH);
    }

    // ========== Initialization ==========
    /// @notice Initialize the contract
    /// @param deployerOwner Address used for initial setup
    /// @param pendingOwner Address eligible to complete ownership transfer
    /// @param referral_ Optional Lido referral (use address(0) for default)
    function initialize(address deployerOwner, address pendingOwner, address referral_) external initializer {
        _initializeOwner(deployerOwner, pendingOwner);
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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit Upgraded(newImplementation);
    }

    // =================================================================
    // ====================== USER FACING ZAPS =========================
    // =================================================================

    /// @notice Zap ETH → stETH → wstETH → Genesis in one transaction
    /// @dev Includes slippage protection against front-running/MEV
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWstEthOut Minimum acceptable wstETH (use preview for 0.1-0.5% buffer)
    /// @param minEthEquivalentOut Minimum acceptable ETH value (slippage protection)
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapEth(address receiver, uint256 minWstEthOut, uint256 minEthEquivalentOut)
        external
        payable
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 ethIn = msg.value;

        // 1. ETH → stETH via Lido
        uint256 stEthReceived = _convertEthToStEth(ethIn);
        // 2. stETH → wstETH
        sharesOut = _convertStEthToWstEth(stEthReceived);
        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert IZapErrors.SlippageTooHighWstETH(sharesOut, minWstEthOut);
        // 4. Value protection
        (uint256 ethValueNow,) = _getCurrentValues(sharesOut);
        if (ethValueNow < minEthEquivalentOut) {
            revert IZapErrors.SlippageTooHighETHValue(ethValueNow, minEthEquivalentOut);
        }
        // 5. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 6. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stEthNow) = _getCurrentValues(sharesOut);
        emit ZappedETH(_msgSender(), receiver, ethIn, sharesOut, ethNow, stEthNow);
    }

    /// @notice Zap existing stETH → wstETH → Genesis
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWstEthOut Minimum acceptable wstETH out
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapStEth(uint256 stEthAmount, address receiver, uint256 minWstEthOut)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        // 1. Transfer stETH from user
        IERC20(STETH).safeTransferFrom(_msgSender(), address(this), stEthAmount);
        // 2. stETH → wstETH
        sharesOut = _convertStEthToWstEth(stEthAmount);
        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert IZapErrors.SlippageTooHighWstETH(sharesOut, minWstEthOut);
        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stEthNow) = _getCurrentValues(sharesOut);
        emit ZappedStETH(_msgSender(), receiver, stEthAmount, sharesOut, ethNow, stEthNow);
    }

    /// @notice Zap stETH → wstETH → Genesis using permit (single transaction, no approval needed)
    /// @dev Flow: Permit stETH → stETH → wstETH → Genesis deposit
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the Genesis shares
    /// @param minWstEthOut Minimum wstETH to receive (slippage protection)
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return sharesOut Amount of Genesis shares minted
    function zapStEthWithPermit(
        uint256 stEthAmount,
        address receiver,
        uint256 minWstEthOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 sharesOut) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        _permitStEth(stEthAmount, deadline, v, r, s);

        // 1. Transfer stETH from user
        IERC20(STETH).safeTransferFrom(_msgSender(), address(this), stEthAmount);
        // 2. stETH → wstETH
        sharesOut = _convertStEthToWstEth(stEthAmount);
        // 3. Slippage protection
        if (sharesOut < minWstEthOut) revert IZapErrors.SlippageTooHighWstETH(sharesOut, minWstEthOut);
        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 5. Emit real-time values for indexers/frontends
        (uint256 ethNow, uint256 stEthNow) = _getCurrentValues(sharesOut);
        emit ZappedStETH(_msgSender(), receiver, stEthAmount, sharesOut, ethNow, stEthNow);
    }

    // =================================================================
    // ====================== INTERNAL HELPERS =========================
    // =================================================================

    /// @notice Convert ETH to stETH via Lido
    /// @param ethAmount Amount of ETH to convert
    /// @return stEthReceived Amount of stETH received (using balance checks, never trust return value)
    function _convertEthToStEth(uint256 ethAmount) internal returns (uint256 stEthReceived) {
        uint256 stEthBefore = IERC20(STETH).balanceOf(address(this));
        ISTETHV2(STETH).submit{value: ethAmount}(referral);
        stEthReceived = IERC20(STETH).balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert IZapErrors.NoStETHReceived();
    }

    /// @notice Convert stETH to wstETH
    /// @param stEthAmount Amount of stETH to convert
    /// @return wstEthReceived Amount of wstETH received (using balance checks, never trust return value)
    function _convertStEthToWstEth(uint256 stEthAmount) internal returns (uint256 wstEthReceived) {
        IERC20(STETH).forceApprove(WSTETH, stEthAmount);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        wstEthReceived = IERC20(WSTETH).balanceOf(address(this)) - wstEthBefore;
        if (wstEthReceived == 0) revert IZapErrors.NoStETHReceived();
    }

    /// @notice Helper to handle stETH permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitStEth(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(STETH).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Deposit wstETH into Genesis and validate shares
    /// @param amount Amount of wstETH to deposit
    /// @param receiver Address receiving Genesis shares
    function _depositToGenesis(uint256 amount, address receiver) internal {
        if (amount == 0) revert IZapErrors.ZeroAmount();

        uint256 balance = IERC20(WSTETH).balanceOf(address(this));
        if (balance < amount) revert IZapErrors.InsufficientBalance(balance, amount);

        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 sharesBefore = IGenesis(GENESIS).balanceOf(receiver);

        uint256 currentAllowance = IERC20(WSTETH).allowance(address(this), GENESIS);
        if (currentAllowance < amount) {
            if (currentAllowance > 0) {
                IERC20(WSTETH).approve(GENESIS, 0);
            }
            IERC20(WSTETH).approve(GENESIS, type(uint256).max);
        }

        IGenesis(GENESIS).deposit(amount, receiver);

        uint256 sharesAfter = IGenesis(GENESIS).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != amount) revert IZapErrors.MintMismatchExpected(amount, sharesReceived);
    }

    /// @notice Returns real-time redeemable values for any wstETH amount
    /// @param wstEthAmount Amount of wstETH
    /// @return ethValue Equivalent ETH value
    /// @return stEthValue Equivalent stETH value
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
        uint256 stEthShares = IStETH(STETH).getSharesByPooledEth(ethAmount);
        uint256 stEthAmount = IStETH(STETH).getPooledEthByShares(stEthShares);
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
    function previewGenesisFromStEth(uint256 stEthAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wstEthAmount)
    {
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

    /// @notice Rescue any ERC20 (except stETH/wstETH/Genesis which should never be stuck)
    function rescueToken(address token) external onlyOwner {
        if (token == STETH || token == WSTETH || token == GENESIS) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // =================================================================
    // ====================== RECEIVE / FALLBACK =======================
    // =================================================================

    receive() external payable {}

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}
