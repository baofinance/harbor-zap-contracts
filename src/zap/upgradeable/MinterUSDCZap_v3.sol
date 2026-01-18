// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IFxUSDDiamondV2} from "src/interfaces/IFxUSD.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {FxSAVEConstants} from "src/constants/ethereum/FxSAVEConstants.sol";

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
    address public constant USDC = FxSAVEConstants.USDC;

    /// @notice fxSAVE vault address (mainnet)
    address public constant FXSAVE = FxSAVEConstants.FXSAVE;

    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address public constant FXUSD_DIAMOND = FxSAVEConstants.FXUSD_DIAMOND;

    /// @notice fxUSD swap router/converter address (for USDC and fxUSD deposits)
    address public constant FXUSD_SWAP_ROUTER = FxSAVEConstants.FXUSD_SWAP_ROUTER;

    /// @notice fxUSD token address (mainnet)
    address public constant FXUSD = FxSAVEConstants.FXUSD;

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

    /// @notice Emitted when fxSAVE is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param fxSaveAmount Amount of fxSAVE deposited
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event FXSAVEZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 fxSaveAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    event StabilityPoolAllowlistUpdated(address indexed stabilityPool, bool allowed);
    event Upgraded(address indexed implementation);

    // ============ Constructor ============

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_) {
        _disableInitializers();

        if (minter_ == address(0)) revert IZapErrors.ZeroAddress();

        // Verify that fxSAVE matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (FXSAVE != expectedCollateral) {
            revert IZapErrors.CollateralMismatch(expectedCollateral, FXSAVE);
        }

        MINTER = minter_;
    }

    // ============ Initialization ============

    /// @notice Initialize the contract
    /// @param deployerOwner Address used for initial setup
    /// @param pendingOwner Address eligible to complete ownership transfer
    function initialize(address deployerOwner, address pendingOwner) external initializer {
        _initializeOwner(deployerOwner, pendingOwner);
        __UUPSUpgradeable_init();
        __Context_init();
        __ReentrancyGuardTransient_init();
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit Upgraded(newImplementation);
    } // solhint-disable-line no-empty-blocks

    // ============ External Functions ============

    /// @notice Zap USDC into pegged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint pegged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapUsdcToPegged(uint256 usdcAmount, address receiver, uint256 minPeggedOut)
        external
        nonReentrant
        returns (uint256 peggedOut)
    {
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut) = _zapToPegged(USDC, usdcAmount, receiver, minPeggedOut);

        emit USDCZappedToPegged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut);
    }

    /// @notice Zap USDC into leveraged tokens in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint leveraged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapUsdcToLeveraged(uint256 usdcAmount, address receiver, uint256 minLeveragedOut)
        external
        nonReentrant
        returns (uint256 leveragedOut)
    {
        uint256 fxSaveAmount;
        (fxSaveAmount, leveragedOut) = _zapToLeveraged(USDC, usdcAmount, receiver, minLeveragedOut);

        emit USDCZappedToLeveraged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, leveragedOut);
    }

    /// @notice Zap fxUSD into pegged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint pegged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapFxUsdToPegged(uint256 fxUsdAmount, address receiver, uint256 minPeggedOut)
        external
        nonReentrant
        returns (uint256 peggedOut)
    {
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut) = _zapToPegged(FXUSD, fxUsdAmount, receiver, minPeggedOut);

        emit FXUSDZappedToPegged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut);
    }

    /// @notice Zap fxUSD into leveraged tokens in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint leveraged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapFxUsdToLeveraged(uint256 fxUsdAmount, address receiver, uint256 minLeveragedOut)
        external
        nonReentrant
        returns (uint256 leveragedOut)
    {
        uint256 fxSaveAmount;
        (fxSaveAmount, leveragedOut) = _zapToLeveraged(FXUSD, fxUsdAmount, receiver, minLeveragedOut);

        emit FXUSDZappedToLeveraged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, leveragedOut);
    }

    /// @notice Zap USDC into StabilityPool in one transaction
    /// @dev Flow: USDC → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromFxSave() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapUsdcToStabilityPool(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut, deposited) =
            _zapToStabilityPoolFromToken(USDC, usdcAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut);

        emit USDCZappedToStabilityPool(
            _msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    /// @notice Zap fxUSD into StabilityPool in one transaction
    /// @dev Flow: fxUSD → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromFxSave() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapFxUsdToStabilityPool(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            FXUSD, fxUsdAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut
        );

        emit FXUSDZappedToStabilityPool(
            _msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    /// @notice Zap fxSAVE into StabilityPool in one transaction
    /// @dev Flow: fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromFxSave() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param fxSaveAmount Amount of fxSAVE to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromFxSave with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapFxSaveToStabilityPool(
        uint256 fxSaveAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        (fxSaveAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            FXSAVE, fxSaveAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut
        );

        emit FXSAVEZappedToStabilityPool(
            _msgSender(), MINTER, receiver, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    // ============ Permit-Based Functions ============

    /// @notice Zap USDC into pegged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit USDC → USDC → fxSAVE → Minter mint pegged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    function zapUsdcToPeggedWithPermit(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut) {
        _permitUsdc(usdcAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut) = _zapToPegged(USDC, usdcAmount, receiver, minPeggedOut);

        emit USDCZappedToPegged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut);
    }

    /// @notice Zap USDC into leveraged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit USDC → USDC → fxSAVE → Minter mint leveraged
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapUsdcToLeveragedWithPermit(
        uint256 usdcAmount,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 leveragedOut) {
        _permitUsdc(usdcAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, leveragedOut) = _zapToLeveraged(USDC, usdcAmount, receiver, minLeveragedOut);

        emit USDCZappedToLeveraged(_msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, leveragedOut);
    }

    /// @notice Zap fxUSD into pegged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit fxUSD → fxUSD → fxSAVE → Minter mint pegged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    function zapFxUsdToPeggedWithPermit(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut) {
        _permitFxUsd(fxUsdAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut) = _zapToPegged(FXUSD, fxUsdAmount, receiver, minPeggedOut);

        emit FXUSDZappedToPegged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut);
    }

    /// @notice Zap fxUSD into leveraged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit fxUSD → fxUSD → fxSAVE → Minter mint leveraged
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapFxUsdToLeveragedWithPermit(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 leveragedOut) {
        _permitFxUsd(fxUsdAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, leveragedOut) = _zapToLeveraged(FXUSD, fxUsdAmount, receiver, minLeveragedOut);

        emit FXUSDZappedToLeveraged(_msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, leveragedOut);
    }

    /// @notice Zap USDC into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit USDC → USDC → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @param usdcAmount Amount of USDC to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapUsdcToStabilityPoolWithPermit(
        uint256 usdcAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _permitUsdc(usdcAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut, deposited) =
            _zapToStabilityPoolFromToken(USDC, usdcAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut);

        emit USDCZappedToStabilityPool(
            _msgSender(), MINTER, receiver, usdcAmount, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    /// @notice Zap fxUSD into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit fxUSD → fxUSD → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @param fxUsdAmount Amount of fxUSD to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapFxUsdToStabilityPoolWithPermit(
        uint256 fxUsdAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _permitFxUsd(fxUsdAmount, deadline, v, r, s);
        uint256 fxSaveAmount;
        (fxSaveAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            FXUSD, fxUsdAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut
        );

        emit FXUSDZappedToStabilityPool(
            _msgSender(), MINTER, receiver, fxUsdAmount, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    /// @notice Zap fxSAVE into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit fxSAVE → fxSAVE → Minter mint pegged → StabilityPool deposit
    /// @param fxSaveAmount Amount of fxSAVE to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapFxSaveToStabilityPoolWithPermit(
        uint256 fxSaveAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _permitFxSave(fxSaveAmount, deadline, v, r, s);
        (fxSaveAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            FXSAVE, fxSaveAmount, receiver, minPeggedOut, stabilityPool, minStabilityPoolOut
        );

        emit FXSAVEZappedToStabilityPool(
            _msgSender(), MINTER, receiver, fxSaveAmount, peggedOut, stabilityPool, deposited
        );
    }

    // ============ Internal Helper Functions ============

    /// @notice Helper to handle USDC permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitUsdc(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(USDC).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Helper to handle fxUSD permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitFxUsd(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(FXUSD).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Helper to handle fxSAVE permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitFxSave(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(FXSAVE).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Convert USDC or fxUSD to fxSAVE via diamond contract
    /// @param tokenIn Token to convert (USDC or fxUSD)
    /// @param amountIn Amount of tokenIn to convert
    /// @return fxSaveAmount Amount of fxSAVE received
    function _convertToFxSave(address tokenIn, uint256 amountIn) internal returns (uint256 fxSaveAmount) {
        // Pull token from user
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        // tokenIn → fxSAVE via diamond contract
        IERC20 token = IERC20(tokenIn);
        _safeApprove(token, FXUSD_DIAMOND, amountIn);

        bytes memory swapData =
            abi.encodeWithSelector(FxSAVEConstants.CONVERT_SELECTOR, tokenIn, amountIn, uint256(0), "");

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: tokenIn, amount: amountIn, target: FXUSD_SWAP_ROUTER, data: swapData, minOut: 0, signature: ""
        });

        uint256 fxSaveBalanceBefore = IERC20(FXSAVE).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, tokenIn, 0, address(this));
        uint256 fxSaveBalanceAfter = IERC20(FXSAVE).balanceOf(address(this));
        fxSaveAmount = fxSaveBalanceAfter - fxSaveBalanceBefore;
        if (fxSaveAmount == 0) revert IZapErrors.NoFxSaveReceived();
    }

    /// @notice Zap a token into pegged tokens and reset allowances
    /// @param tokenIn Token to zap (USDC or fxUSD)
    /// @param amountIn Amount of tokenIn to zap
    /// @param receiver Address receiving pegged tokens
    /// @param minPeggedOut Minimum pegged tokens to receive
    /// @return fxSaveAmount Amount of fxSAVE received
    /// @return peggedOut Amount of pegged tokens minted
    function _zapToPegged(address tokenIn, uint256 amountIn, address receiver, uint256 minPeggedOut)
        internal
        returns (uint256 fxSaveAmount, uint256 peggedOut)
    {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        fxSaveAmount = _convertToFxSave(tokenIn, amountIn);
        peggedOut = _mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);
        _resetAllowances();
    }

    /// @notice Zap a token into leveraged tokens and reset allowances
    /// @param tokenIn Token to zap (USDC or fxUSD)
    /// @param amountIn Amount of tokenIn to zap
    /// @param receiver Address receiving leveraged tokens
    /// @param minLeveragedOut Minimum leveraged tokens to receive
    /// @return fxSaveAmount Amount of fxSAVE received
    /// @return leveragedOut Amount of leveraged tokens minted
    function _zapToLeveraged(address tokenIn, uint256 amountIn, address receiver, uint256 minLeveragedOut)
        internal
        returns (uint256 fxSaveAmount, uint256 leveragedOut)
    {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        fxSaveAmount = _convertToFxSave(tokenIn, amountIn);
        leveragedOut = _mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);
        _resetAllowances();
    }

    /// @notice Zap a token into StabilityPool via minted pegged tokens
    /// @param tokenIn Token to zap (USDC, fxUSD, or fxSAVE)
    /// @param amountIn Amount of tokenIn to zap
    /// @param receiver Address receiving StabilityPool deposit
    /// @param minPeggedOut Minimum pegged tokens to receive
    /// @param stabilityPool StabilityPool address
    /// @param minStabilityPoolOut Minimum StabilityPool deposit amount
    /// @return fxSaveAmount Amount of fxSAVE used to mint pegged tokens
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function _zapToStabilityPoolFromToken(
        address tokenIn,
        uint256 amountIn,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 fxSaveAmount, uint256 peggedOut, uint256 deposited) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();

        if (tokenIn == FXSAVE) {
            IERC20(FXSAVE).safeTransferFrom(_msgSender(), address(this), amountIn);
            fxSaveAmount = amountIn;
        } else {
            fxSaveAmount = _convertToFxSave(tokenIn, amountIn);
        }

        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(fxSaveAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        _resetAllowances();
    }

    /// @notice Mint pegged tokens and validate the result
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function _mintPeggedToken(uint256 fxSaveAmount, address receiver, uint256 minPeggedOut)
        internal
        returns (uint256 peggedOut)
    {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        uint256 peggedBalanceBefore = IERC20(peggedToken).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(fxSaveAmount, receiver, minPeggedOut);

        // Validate that tokens were actually minted
        uint256 peggedBalanceAfter = IERC20(peggedToken).balanceOf(receiver);
        if (peggedBalanceAfter - peggedBalanceBefore != peggedOut || peggedOut == 0) {
            revert IZapErrors.MintFailed();
        }
    }

    /// @notice Mint leveraged tokens and validate the result
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function _mintLeveragedToken(uint256 fxSaveAmount, address receiver, uint256 minLeveragedOut)
        internal
        returns (uint256 leveragedOut)
    {
        address leveragedToken = IMinter(MINTER).LEVERAGED_TOKEN();
        uint256 leveragedBalanceBefore = IERC20(leveragedToken).balanceOf(receiver);
        IERC20(FXSAVE).forceApprove(MINTER, fxSaveAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(fxSaveAmount, receiver, minLeveragedOut);

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
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedAmount minus small rounding buffer ~0.1%)
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
            revert IZapErrors.CollateralMismatch(peggedToken, poolAssetToken);
        }

        // Verify contract has the pegged tokens to deposit (never trust return values)
        uint256 balanceBefore = IERC20(peggedToken).balanceOf(address(this));
        if (balanceBefore < peggedAmount) {
            revert IZapErrors.InsufficientBalance(balanceBefore, peggedAmount);
        }

        // Approve and deposit into StabilityPool
        IERC20(peggedToken).forceApprove(stabilityPool, peggedAmount);
        deposited = IStabilityPool(stabilityPool).deposit(peggedAmount, receiver, minStabilityPoolOut);

        // Verify the full amount was deposited (stability pool deposits don't incur fees)
        uint256 balanceAfter = IERC20(peggedToken).balanceOf(address(this));
        uint256 balanceDecrease = balanceBefore - balanceAfter;

        // Verify balance decreased by exactly peggedAmount (no fees on stability pool deposits)
        if (balanceDecrease != peggedAmount) {
            revert IZapErrors.DepositFailed();
        }

        // Verify returned deposited amount matches what we sent (stability pool deposits don't incur fees)
        if (deposited != peggedAmount) {
            revert IZapErrors.DepositFailed();
        }

        // Reset approval
        IERC20(peggedToken).forceApprove(stabilityPool, 0);
    }

    /// @notice Reset token allowances to zero
    function _resetAllowances() internal {
        IERC20(USDC).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXUSD).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(FXSAVE).forceApprove(MINTER, 0);
    }

    /// @notice Safely set allowance to a target amount
    /// @param token Token to approve
    /// @param spender Spender address
    /// @param amount Target allowance amount
    function _safeApprove(IERC20 token, address spender, uint256 amount) internal {
        uint256 current = token.allowance(address(this), spender);
        if (current == amount) return;
        if (current > 0) {
            token.safeDecreaseAllowance(spender, current);
        }
        if (amount > 0) {
            token.safeIncreaseAllowance(spender, amount);
        }
    }

    // ============ View Functions (Preview) ============

    /// @notice Preview the expected pegged token output from a fxSAVE amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    function previewPeggedFromFxSave(uint256 fxSaveAmount) external view returns (uint256 peggedOut) {
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(fxSaveAmount);
    }

    /// @notice Preview the expected leveraged token output from a fxSAVE amount
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    function previewLeveragedFromFxSave(uint256 fxSaveAmount) external view returns (uint256 leveragedOut) {
        (,,,, leveragedOut,,) = IMinter(MINTER).mintLeveragedTokenDryRun(fxSaveAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a fxSAVE amount
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param fxSaveAmount Amount of fxSAVE to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    function previewStabilityPoolFromFxSave(uint256 fxSaveAmount) external view returns (uint256 peggedOut) {
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(fxSaveAmount);
    }

    /// @notice Human-readable zap name based on the pegged token
    function zapName() external view returns (string memory) {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        return string(abi.encodePacked("Minter zap ", IERC20Metadata(peggedToken).name()));
    }

    // ============ Owner Functions ============

    /// @notice Set the allowed status of a stability pool
    /// @param stabilityPool Address of the stability pool
    /// @param allowed Whether the stability pool is allowed
    function setStabilityPoolAllowed(address stabilityPool, bool allowed) external onlyOwner {
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();
        allowedStabilityPools[stabilityPool] = allowed;
        emit StabilityPoolAllowlistUpdated(stabilityPool, allowed);
    }

    function rescueEth() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        if (token == USDC || token == FXUSD || token == FXSAVE || token == MINTER) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
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

