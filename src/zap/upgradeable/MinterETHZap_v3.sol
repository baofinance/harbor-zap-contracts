// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {ISTETHV2, IStETHView} from "src/interfaces/IStETH.sol";
import {IWstETHWrapV2, IWstETHView} from "src/interfaces/IWstETH.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title MinterETHZapV3
/// @notice One-click zapper for minting pegged or leveraged tokens with ETH or stETH via wstETH
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: ETH → stETH → wstETH → Minter mint
/// @dev Flow: stETH → wstETH → Minter mint
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract MinterETHZap_v3 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
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
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    // ============ Configurable ============

    address public referral;

    /// @notice Mapping of allowed stability pool addresses
    mapping(address => bool) public allowedStabilityPools;

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

    /// @notice Emitted when ETH is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param ethAmount Amount of ETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event ETHZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 ethAmount,
        uint256 wstEthAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    /// @notice Emitted when stETH is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param stEthAmount Amount of stETH deposited
    /// @param wstEthAmount Amount of wstETH received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event STETHZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 stEthAmount,
        uint256 wstEthAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);
    event StabilityPoolAllowlistUpdated(address indexed stabilityPool, bool allowed);

    // ============ Constructor ============

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_, address referral_) {
        _disableInitializers();

        if (minter_ == address(0)) revert IZapErrors.InvalidAddress();

        // Verify that wstETH matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (WSTETH != expectedCollateral) {
            revert IZapErrors.WstETHMismatch(expectedCollateral, WSTETH);
        }

        MINTER = minter_;
        
        // Set referral in constructor for immutable-like behavior (can be changed via initialize)
        address initialReferral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;
        referral = initialReferral;
    }

    // ============ Initialization ============

    /// @notice Initialize the contract
    /// @param owner_ Address that will own the contract
    /// @param referral_ Lido referral address (or address(0) to use default)
    function initialize(address owner_, address referral_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();

        // Set referral if provided, otherwise keep constructor value
        if (referral_ != address(0)) {
            referral = referral_;
            emit ReferralUpdated(address(0), referral_);
        }
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    // ============ External Functions ============

    /// @notice Zap ETH into pegged tokens in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Minter mint pegged
    /// @dev Use previewPeggedFromEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapEthToPegged(
        address receiver,
        uint256 minPeggedOut
    ) external payable nonReentrant returns (uint256 peggedOut) {
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        uint256 ethAmount = msg.value;
        uint256 wstEthAmount = _convertEthToWstEth(ethAmount);
        peggedOut = _mintPeggedToken(wstEthAmount, receiver, minPeggedOut);

        emit ETHZappedToPegged(_msgSender(), MINTER, receiver, ethAmount, wstEthAmount, peggedOut);
        _resetAllowances();
    }

    /// @notice Zap ETH into leveraged tokens in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Minter mint leveraged
    /// @dev Use previewLeveragedFromEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapEthToLeveraged(
        address receiver,
        uint256 minLeveragedOut
    ) external payable nonReentrant returns (uint256 leveragedOut) {
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        uint256 ethAmount = msg.value;
        uint256 wstEthAmount = _convertEthToWstEth(ethAmount);
        leveragedOut = _mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);

        emit ETHZappedToLeveraged(_msgSender(), MINTER, receiver, ethAmount, wstEthAmount, leveragedOut);
        _resetAllowances();
    }

    /// @notice Zap stETH into pegged tokens in one transaction
    /// @dev Flow: stETH → wstETH → Minter mint pegged
    /// @dev Use previewPeggedFromStEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapStEthToPegged(
        uint256 stEthAmount,
        address receiver,
        uint256 minPeggedOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        peggedOut = _mintPeggedToken(wstEthAmount, receiver, minPeggedOut);

        emit STETHZappedToPegged(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, peggedOut);
        _resetAllowances();
    }

    /// @notice Zap stETH into leveraged tokens in one transaction
    /// @dev Flow: stETH → wstETH → Minter mint leveraged
    /// @dev Use previewLeveragedFromStEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapStEthToLeveraged(
        uint256 stEthAmount,
        address receiver,
        uint256 minLeveragedOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        leveragedOut = _mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);

        emit STETHZappedToLeveraged(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, leveragedOut);
        _resetAllowances();
    }

    /// @notice Zap ETH into StabilityPool in one transaction
    /// @dev Flow: ETH → stETH → wstETH → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromEth with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (use previewStabilityPoolFromEth with slippage buffer)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapEthToStabilityPool(
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external payable nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();
        if (stabilityPool == address(0)) revert IZapErrors.InvalidAddress();

        uint256 ethAmount = msg.value;
        uint256 wstEthAmount = _convertEthToWstEth(ethAmount);
        
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wstEthAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        
        emit ETHZappedToStabilityPool(_msgSender(), MINTER, receiver, ethAmount, wstEthAmount, peggedOut, stabilityPool, deposited);
        _resetAllowances();
    }

    /// @notice Zap stETH into StabilityPool in one transaction
    /// @dev Flow: stETH → wstETH → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromStEth() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromStEth with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (use previewStabilityPoolFromStEth with slippage buffer)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapStEthToStabilityPool(
        uint256 stEthAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();
        if (stabilityPool == address(0)) revert IZapErrors.InvalidAddress();

        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wstEthAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        
        emit STETHZappedToStabilityPool(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, peggedOut, stabilityPool, deposited);
        _resetAllowances();
    }

    // ============ Permit-Based Functions ============

    /// @notice Zap stETH into pegged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit stETH → stETH → wstETH → Minter mint pegged
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    function zapStEthToPeggedWithPermit(
        uint256 stEthAmount,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        _permitStEth(stEthAmount, deadline, v, r, s);
        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        peggedOut = _mintPeggedToken(wstEthAmount, receiver, minPeggedOut);

        emit STETHZappedToPegged(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, peggedOut);
        _resetAllowances();
    }

    /// @notice Zap stETH into leveraged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit stETH → stETH → wstETH → Minter mint leveraged
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapStEthToLeveragedWithPermit(
        uint256 stEthAmount,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();

        _permitStEth(stEthAmount, deadline, v, r, s);
        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        leveragedOut = _mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);

        emit STETHZappedToLeveraged(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, leveragedOut);
        _resetAllowances();
    }

    /// @notice Zap stETH into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit stETH → stETH → wstETH → Minter mint pegged → StabilityPool deposit
    /// @param stEthAmount Amount of stETH to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapStEthToStabilityPoolWithPermit(
        uint256 stEthAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        if (stEthAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.InvalidAddress();
        if (stabilityPool == address(0)) revert IZapErrors.InvalidAddress();

        _permitStEth(stEthAmount, deadline, v, r, s);
        uint256 wstEthAmount = _convertStEthToWstEth(stEthAmount);
        
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wstEthAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);

        emit STETHZappedToStabilityPool(_msgSender(), MINTER, receiver, stEthAmount, wstEthAmount, peggedOut, stabilityPool, deposited);
        _resetAllowances();
    }

    // ============ Internal Helper Functions ============

    /// @notice Helper to handle stETH permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitStEth(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(STETH).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Convert ETH to wstETH via stETH
    /// @param ethAmount Amount of ETH to convert
    /// @return wstEthAmount Amount of wstETH received
    function _convertEthToWstEth(uint256 ethAmount) internal returns (uint256 wstEthAmount) {
        // 1. ETH → stETH via Lido (never trust return value, use balance change)
        uint256 stEthBefore = IERC20(STETH).balanceOf(address(this));
        ISTETHV2(STETH).submit{value: ethAmount}(referral);
        uint256 stEthReceived = IERC20(STETH).balanceOf(address(this)) - stEthBefore;
        if (stEthReceived == 0) revert IZapErrors.ZeroAmount();

        // 2. stETH → wstETH (use balance change to get actual amount)
        wstEthAmount = _wrapStEthToWstEth(stEthReceived);
    }

    /// @notice Convert stETH to wstETH
    /// @param stEthAmount Amount of stETH to convert
    /// @return wstEthAmount Amount of wstETH received
    function _convertStEthToWstEth(uint256 stEthAmount) internal returns (uint256 wstEthAmount) {
        // 1. Pull stETH from user
        IERC20(STETH).safeTransferFrom(_msgSender(), address(this), stEthAmount);

        // 2. stETH → wstETH
        wstEthAmount = _wrapStEthToWstEth(stEthAmount);
    }

    /// @notice Wrap stETH to wstETH (assumes stETH is already in this contract)
    /// @param stEthAmount Amount of stETH to wrap
    /// @return wstEthAmount Amount of wstETH received
    function _wrapStEthToWstEth(uint256 stEthAmount) internal returns (uint256 wstEthAmount) {
        IERC20(STETH).forceApprove(WSTETH, stEthAmount);
        uint256 wstEthBefore = IERC20(WSTETH).balanceOf(address(this));
        IWstETHWrapV2(WSTETH).wrap(stEthAmount);
        uint256 wstEthAfter = IERC20(WSTETH).balanceOf(address(this));
        wstEthAmount = wstEthAfter - wstEthBefore;
        if (wstEthAmount == 0) revert IZapErrors.ZeroAmount();
    }

    /// @notice Mint pegged tokens and validate the result
    /// @param wstEthAmount Amount of wstETH to use for minting
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function _mintPeggedToken(uint256 wstEthAmount, address receiver, uint256 minPeggedOut) internal returns (uint256 peggedOut) {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        uint256 peggedBalanceBefore = IERC20(peggedToken).balanceOf(receiver);
        IERC20(WSTETH).forceApprove(MINTER, wstEthAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(wstEthAmount, receiver, minPeggedOut);
        
        // Validate that tokens were actually minted
        uint256 peggedBalanceAfter = IERC20(peggedToken).balanceOf(receiver);
        if (peggedBalanceAfter - peggedBalanceBefore != peggedOut || peggedOut == 0) {
            revert IZapErrors.MintFailed();
        }
    }

    /// @notice Mint leveraged tokens and validate the result
    /// @param wstEthAmount Amount of wstETH to use for minting
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function _mintLeveragedToken(uint256 wstEthAmount, address receiver, uint256 minLeveragedOut) internal returns (uint256 leveragedOut) {
        address leveragedToken = IMinter(MINTER).LEVERAGED_TOKEN();
        uint256 leveragedBalanceBefore = IERC20(leveragedToken).balanceOf(receiver);
        IERC20(WSTETH).forceApprove(MINTER, wstEthAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(wstEthAmount, receiver, minLeveragedOut);
        
        // Validate that tokens were actually minted
        uint256 leveragedBalanceAfter = IERC20(leveragedToken).balanceOf(receiver);
        if (leveragedBalanceAfter - leveragedBalanceBefore != leveragedOut || leveragedOut == 0) {
            revert IZapErrors.MintFailed();
        }
    }

    /// @notice Deposit pegged tokens into StabilityPool
    /// @param peggedToken Address of the pegged token
    /// @param stabilityPool Address of the StabilityPool
    /// @param peggedAmount Amount of pegged tokens to deposit
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool
    /// @return deposited Amount deposited into StabilityPool
    function _depositToStabilityPool(
        address peggedToken,
        address stabilityPool,
        uint256 peggedAmount,
        address receiver,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 deposited) {
        // Verify stability pool is allowed
        if (!allowedStabilityPools[stabilityPool]) {
            revert IZapErrors.StabilityPoolNotAllowed();
        }
        
        // Verify StabilityPool accepts the correct pegged token
        address poolAssetToken = IStabilityPool(stabilityPool).ASSET_TOKEN();
        if (poolAssetToken != peggedToken) {
            revert IZapErrors.InvalidAddress(); // StabilityPool doesn't accept this pegged token
        }
        
        // Approve and deposit into StabilityPool
        IERC20(peggedToken).forceApprove(stabilityPool, peggedAmount);
        deposited = IStabilityPool(stabilityPool).deposit(peggedAmount, receiver, minStabilityPoolOut);
        
        // Reset approval
        IERC20(peggedToken).forceApprove(stabilityPool, 0);
    }

    /// @notice Reset token allowances to zero
    function _resetAllowances() internal {
        IERC20(STETH).forceApprove(WSTETH, 0);
        IERC20(WSTETH).forceApprove(MINTER, 0);
    }

    // ============ View Functions (Preview) ============

    /// @notice Internal helper to preview ETH → wstETH conversion
    /// @param ethAmount Amount of ETH
    /// @return wstEthAmount Expected wstETH amount
    function _previewWstEthFromEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        // Calculate stETH shares that will be minted for this ETH amount
        uint256 stEthShares = IStETHView(STETH).getSharesByPooledEth(ethAmount);
        // Convert shares back to stETH token amount (accounts for rounding)
        uint256 stEthAmount = IStETHView(STETH).getPooledEthByShares(stEthShares);
        // Convert stETH to wstETH
        wstEthAmount = IWstETHView(WSTETH).getWstETHByStETH(stEthAmount);
    }

    /// @notice Preview the expected wstETH output from an ETH amount
    /// @param ethAmount Amount of ETH
    /// @return wstEthAmount Expected wstETH amount
    function previewWstEthFromEth(uint256 ethAmount) external view returns (uint256 wstEthAmount) {
        wstEthAmount = _previewWstEthFromEth(ethAmount);
    }

    /// @notice Preview the expected wstETH output from a stETH amount
    /// @param stEthAmount Amount of stETH
    /// @return wstEthAmount Expected wstETH amount
    function previewWstEthFromStEth(uint256 stEthAmount) external view returns (uint256 wstEthAmount) {
        wstEthAmount = IWstETHView(WSTETH).getWstETHByStETH(stEthAmount);
    }

    /// @notice Preview the expected pegged token output from an ETH amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param ethAmount Amount of ETH to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewPeggedFromEth(uint256 ethAmount) external view returns (uint256 peggedOut, uint256 wstEthAmount) {
        wstEthAmount = _previewWstEthFromEth(ethAmount);
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview the expected leveraged token output from an ETH amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param ethAmount Amount of ETH to zap
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewLeveragedFromEth(uint256 ethAmount) external view returns (uint256 leveragedOut, uint256 wstEthAmount) {
        wstEthAmount = _previewWstEthFromEth(ethAmount);
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview the expected pegged token output from a stETH amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param stEthAmount Amount of stETH to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewPeggedFromStEth(uint256 stEthAmount) external view returns (uint256 peggedOut, uint256 wstEthAmount) {
        wstEthAmount = IWstETHView(WSTETH).getWstETHByStETH(stEthAmount);
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview the expected leveraged token output from a stETH amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param stEthAmount Amount of stETH to zap
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    /// @return wstEthAmount Expected wstETH amount
    function previewLeveragedFromStEth(uint256 stEthAmount) external view returns (uint256 leveragedOut, uint256 wstEthAmount) {
        wstEthAmount = IWstETHView(WSTETH).getWstETHByStETH(stEthAmount);
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from an ETH zap
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param ethAmount Amount of ETH to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    /// @return wstEthAmount Expected wstETH amount
    function previewStabilityPoolFromEth(uint256 ethAmount) external view returns (uint256 peggedOut, uint256 wstEthAmount) {
        wstEthAmount = _previewWstEthFromEth(ethAmount);
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wstEthAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a stETH zap
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param stEthAmount Amount of stETH to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    /// @return wstEthAmount Expected wstETH amount
    function previewStabilityPoolFromStEth(uint256 stEthAmount) external view returns (uint256 peggedOut, uint256 wstEthAmount) {
        wstEthAmount = IWstETHView(WSTETH).getWstETHByStETH(stEthAmount);
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wstEthAmount);
    }

    // ============ Owner Functions ============

    function setReferral(address newReferral) external onlyOwner {
        emit ReferralUpdated(referral, newReferral);
        referral = newReferral;
    }

    /// @notice Set the allowed status of a stability pool
    /// @param stabilityPool Address of the stability pool
    /// @param allowed Whether the stability pool is allowed
    function setStabilityPoolAllowed(address stabilityPool, bool allowed) external onlyOwner {
        if (stabilityPool == address(0)) revert IZapErrors.InvalidAddress();
        allowedStabilityPools[stabilityPool] = allowed;
        emit StabilityPoolAllowlistUpdated(stabilityPool, allowed);
    }

    function rescueEth() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // ============ Safety Functions ============

    receive() external payable {
        // Allow contract to receive ETH for recovery
    }

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}

