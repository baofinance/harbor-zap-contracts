// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IFxUSDDiamondV2} from "src/interfaces/IFxUSD.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title MinterUSDCZapV3
/// @notice One-click zapper for minting pegged or leveraged tokens with USDC or fxUSD via fxSAVE
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: USDC/fxUSD → fxSAVE → Minter mint
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract MinterUSDCZap_v3 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice USDC address (mainnet)
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice fxSAVE vault address (mainnet)
    address public constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address public constant FXUSD_DIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;

    /// @notice fxUSD swap router/converter address (for USDC and fxUSD deposits)
    address public constant FXUSD_SWAP_ROUTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;

    /// @notice fxUSD token address (mainnet)
    address public constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;

    // ============ Immutables ============

    /// @notice Minter contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    // ============ Configurable ============

    /// @notice Mapping of allowed stability pool addresses
    mapping(address => bool) public allowedStabilityPools;

    // ============ Events ============

    /// @notice Emitted when USDC is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    event USDCZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when USDC is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param leveragedOut Amount of leveraged tokens minted
    event USDCZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when fxUSD is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    event FXUSDZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when fxUSD is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param leveragedOut Amount of leveraged tokens minted
    event FXUSDZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when USDC is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param usdcAmount Amount of USDC deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event USDCZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    /// @notice Emitted when fxUSD is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param fxUsdAmount Amount of fxUSD deposited
    /// @param fxSaveAmount Amount of fxSAVE received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event FXUSDZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxUsdAmount,
        uint256 fxSaveAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    event StabilityPoolAllowlistUpdated(address indexed stabilityPool, bool allowed);

    // ============ Constructor ============

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_) {
        _disableInitializers();

        if (minter_ == address(0)) revert InvalidAddress();

        // Verify that fxSAVE matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (FXSAVE != expectedCollateral) {
            revert CollateralMismatch(expectedCollateral, FXSAVE);
        }

        MINTER = minter_;
    }

    // ============ Initialization ============

    /// @notice Initialize the contract
    /// @param owner_ Address that will own the contract
    function initialize(address owner_) external initializer {
        _initializeOwner(owner_);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    // ============ External Functions ============

    /// @notice Zap USDC into pegged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint pegged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapUsdcToPegged(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertUsdcToFxSave(usdcAmount);
        peggedOut = _mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);

        emit USDCZappedToPegged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut);
        _resetAllowances();
    }

    /// @notice Zap USDC into leveraged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint leveraged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapUsdcToLeveraged(
        uint256 usdcAmount,
        address receiver,
        uint256 minLeveragedOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertUsdcToFxSave(usdcAmount);
        leveragedOut = _mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);

        emit USDCZappedToLeveraged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, leveragedOut);
        _resetAllowances();
    }

    /// @notice Zap fxUSD into pegged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint pegged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapFxUsdToPegged(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut
    ) external nonReentrant returns (uint256 peggedOut) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertFxUsdToFxSave(fxUsdAmount);
        peggedOut = _mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);

        emit FXUSDZappedToPegged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut);
        _resetAllowances();
    }

    /// @notice Zap fxUSD into leveraged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint leveraged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapFxUsdToLeveraged(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minLeveragedOut
    ) external nonReentrant returns (uint256 leveragedOut) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertFxUsdToFxSave(fxUsdAmount);
        leveragedOut = _mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);

        emit FXUSDZappedToLeveraged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, leveragedOut);
        _resetAllowances();
    }

    /// @notice Zap USDC into StabilityPool in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromFxSave() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapUsdcToStabilityPool(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();
        if (stabilityPool == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertUsdcToFxSave(usdcAmount);
        
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(fxSaveAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        
        emit USDCZappedToStabilityPool(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut, stabilityPool, deposited);
        _resetAllowances();
    }

    /// @notice Zap fxUSD into StabilityPool in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromFxSave() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapFxUsdToStabilityPool(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        if (fxUsdAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert InvalidAddress();
        if (stabilityPool == address(0)) revert InvalidAddress();

        uint256 fxSaveAmount = _convertFxUsdToFxSave(fxUsdAmount);
        
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(fxSaveAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        
        emit FXUSDZappedToStabilityPool(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut, stabilityPool, deposited);
        _resetAllowances();
    }

    // ============ Internal Helper Functions ============

    /// @notice Convert USDC to fxSAVE via diamond contract
    /// @param usdcAmount Amount of USDC to convert
    /// @return fxSaveAmount Amount of fxSAVE received
    function _convertUsdcToFxSave(uint256 usdcAmount) internal returns (uint256 fxSaveAmount) {
        // Pull USDC from user
        IERC20(USDC).safeTransferFrom(_msgSender(), address(this), usdcAmount);

        // USDC → fxSAVE via diamond contract
        IERC20 usdcToken = IERC20(USDC);
        if (usdcToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            usdcToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        usdcToken.forceApprove(FXUSD_DIAMOND, usdcAmount);

        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, USDC, usdcAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: USDC,
            amount: usdcAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, USDC, 0, address(this));
        uint256 fxSaveBalanceAfter = IERC20(FXSAVE).balanceOf(address(this));
        fxSaveAmount = fxSaveBalanceAfter - fxSaveBalanceBefore;
        if (fxSaveAmount == 0) revert ZeroAmount();
    }

    /// @notice Convert fxUSD to fxSAVE via diamond contract
    /// @param fxUsdAmount Amount of fxUSD to convert
    /// @return fxSaveAmount Amount of fxSAVE received
    function _convertFxUsdToFxSave(uint256 fxUsdAmount) internal returns (uint256 fxSaveAmount) {
        // Pull fxUSD from user
        IERC20(FXUSD).safeTransferFrom(_msgSender(), address(this), fxUsdAmount);

        // fxUSD → fxSAVE via diamond contract
        IERC20 fxUsdToken = IERC20(FXUSD);
        if (fxUsdToken.allowance(address(this), FXUSD_DIAMOND) > 0) {
            fxUsdToken.forceApprove(FXUSD_DIAMOND, 0);
        }
        fxUsdToken.forceApprove(FXUSD_DIAMOND, fxUsdAmount);

        bytes memory swapData = abi.encodeWithSelector(0xed52d54c, FXUSD, fxUsdAmount, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: FXUSD,
            amount: fxUsdAmount,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: 0,
            signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, FXUSD, 0, address(this));
        uint256 fxSaveBalanceAfter = IERC20(FXSAVE).balanceOf(address(this));
        fxSaveAmount = fxSaveBalanceAfter - fxSaveBalanceBefore;
        if (fxSaveAmount == 0) revert ZeroAmount();
    }

    /// @notice Mint pegged tokens and validate the result
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function _mintPeggedToken(uint256 fxSaveAmount, address receiver, uint256 minPeggedOut) internal returns (uint256 peggedOut) {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        uint256 peggedBalanceBefore = IERC20(peggedToken).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);
        
        // Validate that tokens were actually minted
        uint256 peggedBalanceAfter = IERC20(peggedToken).balanceOf(receiver);
        if (peggedBalanceAfter - peggedBalanceBefore != peggedOut || peggedOut == 0) {
            revert MintFailed();
        }
    }

    /// @notice Mint leveraged tokens and validate the result
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function _mintLeveragedToken(uint256 fxSaveAmount, address receiver, uint256 minLeveragedOut) internal returns (uint256 leveragedOut) {
        address leveragedToken = IMinter(MINTER).LEVERAGED_TOKEN();
        uint256 leveragedBalanceBefore = IERC20(leveragedToken).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);
        
        // Validate that tokens were actually minted
        uint256 leveragedBalanceAfter = IERC20(leveragedToken).balanceOf(receiver);
        if (leveragedBalanceAfter - leveragedBalanceBefore != leveragedOut || leveragedOut == 0) {
            revert MintFailed();
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
            revert StabilityPoolNotAllowed();
        }
        
        // Verify StabilityPool accepts the correct pegged token
        address poolAssetToken = IStabilityPool(stabilityPool).ASSET_TOKEN();
        if (poolAssetToken != peggedToken) {
            revert InvalidAddress(); // StabilityPool doesn't accept this pegged token
        }
        
        // Approve and deposit into StabilityPool
        IERC20(peggedToken).forceApprove(stabilityPool, peggedAmount);
        deposited = IStabilityPool(stabilityPool).deposit(peggedAmount, receiver, minStabilityPoolOut);
        
        // Reset approval
        IERC20(peggedToken).forceApprove(stabilityPool, 0);
    }

    /// @notice Reset token allowances to zero
    function _resetAllowances() internal {
        IERC20(USDC).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXUSD).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    // ============ View Functions (Preview) ============

    /// @notice Preview the expected pegged token output from a fxSAVE amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    function previewPeggedFromFxSave(uint256 fxSaveAmount) external view returns (uint256 peggedOut) {
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(fxSaveAmount);
    }

    /// @notice Preview the expected leveraged token output from a fxSAVE amount
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    function previewLeveragedFromFxSave(uint256 fxSaveAmount) external view returns (uint256 leveragedOut) {
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(fxSaveAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a fxSAVE amount
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    function previewStabilityPoolFromFxSave(uint256 fxSaveAmount) external view returns (uint256 peggedOut) {
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(fxSaveAmount);
    }

    // ============ Owner Functions ============

    /// @notice Set the allowed status of a stability pool
    /// @param stabilityPool Address of the stability pool
    /// @param allowed Whether the stability pool is allowed
    function setStabilityPoolAllowed(address stabilityPool, bool allowed) external onlyOwner {
        if (stabilityPool == address(0)) revert InvalidAddress();
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
        revert FunctionNotFound();
    }
}

