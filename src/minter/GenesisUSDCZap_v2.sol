// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

/// @notice Interface for the diamond contract's depositToFxSave function
interface IFxUSDDiamondV2 {
    struct ConvertInParams {
        address tokenIn;
        uint256 amount;
        address target;
        bytes data;
        uint256 minOut;
        bytes signature;
    }
    function depositToFxSave(
        ConvertInParams memory params,
        address tokenOut,
        uint256 minShares,
        address receiver
    ) external payable;
}

/// @title GenesisUSDCZapV2 - Production Ready
/// @notice One-click zapper for depositing USDC or fxUSD into Genesis contracts via fxSAVE
/// @dev Enables users to deposit USDC or fxUSD in a single transaction
/// @dev Flow: USDC/fxUSD → fxSAVE → Genesis deposit
/// @author Harbor Yield Protocol
contract GenesisUSDCZapV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    /// @notice USDC address (mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice fxUSD token address (mainnet)
    address public constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    /// @notice fxSAVE vault address (mainnet)
    address public constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address public constant FXUSD_DIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;
    /// @notice fxUSD swap router/converter address (for USDC and fxUSD deposits)
    address public constant FXUSD_SWAP_ROUTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;

    // Selector for IFxProtocolRouter.convert(address,uint256,uint256,bytes)
    bytes4 private constant CONVERT_SELECTOR = 0xed52d54c;

    // ============ Immutables ============
    /// @notice Genesis contract address
    address public immutable GENESIS;

    // ============ Configurable ============
    address public owner;

    // ============ Events ============
    /// @notice Emitted when USDC is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param collateralAmount Amount of collateral deposited to Genesis
    event USDCZappedToGenesis(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 collateralAmount
    );

    /// @notice Emitted when fxUSD is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param collateralAmount Amount of collateral deposited to Genesis
    event FXUSDZappedToGenesis(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 collateralAmount
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============ Errors ============
    /// @notice Thrown when zero amount is provided
    error ZeroAmount();
    /// @notice Thrown when contract addresses are invalid
    error InvalidAddress();
    /// @notice Thrown when fxSAVE address doesn't match Genesis collateral token
    error CollateralMismatch(address expected, address actual);
    error Unauthorized();
    error SlippageExceeded();
    error DepositFailed();
    error FunctionNotFound();

    // ============ Constructor ============
    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept fxSAVE as collateral)
    constructor(address genesis_) {
        if (genesis_ == address(0)) revert InvalidAddress();

        address expected = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (expected != FXSAVE) revert CollateralMismatch(expected, FXSAVE);

        GENESIS = genesis_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    // =============================================================
    // MAIN ZAP FUNCTIONS
    // =============================================================

    /// @notice Zap USDC → fxSAVE → Genesis in one tx
    /// @dev Flow: USDC → fxSAVE → Genesis deposit
    /// @param usdcAmount Amount of USDC to zap
    /// @param minFxSaveOut Minimum fxSAVE to receive (slippage protection)
    /// @param receiver Who gets the Genesis shares
    /// @return collateralAmount Amount of collateral deposited to Genesis
    function zapUsdcToGenesis(
        uint256 usdcAmount,
        uint256 minFxSaveOut,
        address receiver
    ) external nonReentrant returns (uint256 collateralAmount) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull USDC
        IERC20(USDC).safeTransferFrom(msg.sender, address(this), usdcAmount);

        // 2. Convert USDC → fxSAVE via diamond
        uint256 fxSaveReceived = _convertToFxSave(USDC, usdcAmount, minFxSaveOut);

        // 3. Deposit into Genesis
        uint256 sharesBefore = IGenesis(GENESIS).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(GENESIS, fxSaveReceived);
        IGenesis(GENESIS).deposit(fxSaveReceived, receiver);
        
        // Validate that shares were actually minted
        uint256 sharesAfter = IGenesis(GENESIS).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != fxSaveReceived) {
            revert DepositFailed();
        }

        collateralAmount = fxSaveReceived;

        emit USDCZappedToGenesis(msg.sender, GENESIS, receiver, usdcAmount, fxSaveReceived, collateralAmount);

        // Clean approvals
        _safeApprove(IERC20(USDC), FXUSD_DIAMOND, 0);
        _safeApprove(IERC20(FXSAVE), GENESIS, 0);
    }

    /// @notice Zap fxUSD → fxSAVE → Genesis in one tx
    /// @dev Flow: fxUSD → fxSAVE → Genesis deposit
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param minFxSaveOut Minimum fxSAVE to receive
    /// @param receiver Who gets the Genesis shares
    /// @return collateralAmount Amount of collateral deposited to Genesis
    function zapFxUsdToGenesis(
        uint256 fxUsdAmount,
        uint256 minFxSaveOut,
        address receiver
    ) external nonReentrant returns (uint256 collateralAmount) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        // 1. Pull fxUSD
        IERC20(FXUSD).safeTransferFrom(msg.sender, address(this), fxUsdAmount);

        // 2. Convert fxUSD → fxSAVE
        uint256 fxSaveReceived = _convertToFxSave(FXUSD, fxUsdAmount, minFxSaveOut);

        // 3. Deposit into Genesis
        uint256 sharesBefore = IGenesis(GENESIS).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(GENESIS, fxSaveReceived);
        IGenesis(GENESIS).deposit(fxSaveReceived, receiver);
        
        // Validate that shares were actually minted
        uint256 sharesAfter = IGenesis(GENESIS).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != fxSaveReceived) {
            revert DepositFailed();
        }

        collateralAmount = fxSaveReceived;

        emit FXUSDZappedToGenesis(msg.sender, GENESIS, receiver, fxUsdAmount, fxSaveReceived, collateralAmount);

        // Clean approvals
        _safeApprove(IERC20(FXUSD), FXUSD_DIAMOND, 0);
        _safeApprove(IERC20(FXSAVE), GENESIS, 0);
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    function _convertToFxSave(
        address tokenIn,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256 fxSaveReceived) {
        IERC20 token = IERC20(tokenIn);

        // Approve diamond if needed
        _safeApprove(token, FXUSD_DIAMOND, amountIn);

        // Encode converter call: convert(tokenIn, amountIn, 0, "")
        bytes memory data = abi.encodeWithSelector(
            CONVERT_SELECTOR,
            tokenIn,
            amountIn,
            uint256(0),
            bytes("")
        );

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: tokenIn,
            amount: amountIn,
            target: FXUSD_SWAP_ROUTER,
            data: data,
            minOut: minOut,
            signature: ""
        });

        uint256 balanceBefore = IERC20(FXSAVE).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave(params, tokenIn, 0, address(this));
        fxSaveReceived = IERC20(FXSAVE).balanceOf(address(this)) - balanceBefore;

        if (fxSaveReceived < minOut) revert SlippageExceeded();
    }

    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current > 0) {
            token.forceApprove(spender, 0);
        }
        token.forceApprove(spender, amount);
    }

    // =============================================================
    // OWNER FUNCTIONS
    // =============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function rescueETH() external onlyOwner {
        payable(owner).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    // =============================================================
    // FALLBACKS
    // =============================================================

    receive() external payable {}
    fallback() external payable { revert FunctionNotFound(); }
}