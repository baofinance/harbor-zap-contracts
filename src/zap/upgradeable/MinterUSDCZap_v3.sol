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
/// @notice One-click zapper for minting pegged or leveraged tokens with base asset or collateral via wrapped collateral
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: base asset/collateral → wrapped collateral → Minter mint
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

    /// @notice Base asset address (mainnet)
    address public constant USDC = FxSAVEConstants.USDC;

    /// @notice Wrapped collateral vault address (mainnet)
    address public constant FXSAVE = FxSAVEConstants.FXSAVE;

    /// @notice fxUSD Diamond contract address (handles deposits to wrapped collateral)
    address public constant FXUSD_DIAMOND = FxSAVEConstants.FXUSD_DIAMOND;

    /// @notice fxUSD swap router/converter address (for base asset and collateral deposits)
    address public constant FXUSD_SWAP_ROUTER = FxSAVEConstants.FXUSD_SWAP_ROUTER;

    /// @notice Collateral token address (mainnet)
    address public constant FXUSD = FxSAVEConstants.FXUSD;
    address public constant BASE_ASSET = USDC;
    address public constant COLLATERAL_ASSET = FXUSD;
    address public constant WRAPPED_COLLATERAL_ASSET = FXSAVE;

    // ============ Immutables ============

    /// @notice Minter contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    // ============ Configurable ============

    /// @notice Mapping of allowed stability pool addresses
    mapping(address => bool) public allowedStabilityPools;

    // ============ Events ============

    /// @notice Emitted when base asset is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param baseAssetAmount Amount of base asset deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param peggedOut Amount of pegged tokens minted
    event BaseAssetZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when base asset is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param baseAssetAmount Amount of base asset deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param leveragedOut Amount of leveraged tokens minted
    event BaseAssetZappedToLeverage(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when collateral is zapped to mint pegged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the pegged tokens
    /// @param collateralAmount Amount of collateral deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param peggedOut Amount of pegged tokens minted
    event CollateralZappedToPegged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut
    );

    /// @notice Emitted when collateral is zapped to mint leveraged tokens
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the leveraged tokens
    /// @param collateralAmount Amount of collateral deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param leveragedOut Amount of leveraged tokens minted
    event CollateralZappedToLeveraged(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 leveragedOut
    );

    /// @notice Emitted when base asset is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param baseAssetAmount Amount of base asset deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event BaseAssetZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 baseAssetAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    /// @notice Emitted when collateral is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param collateralAmount Amount of collateral deposited
    /// @param wrappedCollateralAmount Amount of wrapped collateral received
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event CollateralZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 collateralAmount,
        uint256 wrappedCollateralAmount,
        uint256 peggedOut,
        address stabilityPool,
        uint256 deposited
    );

    /// @notice Emitted when wrapped collateral is zapped to StabilityPool
    /// @param user Address that initiated the zap
    /// @param minter Address of the Minter contract
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param wrappedCollateralAmount Amount of wrapped collateral deposited
    /// @param peggedOut Amount of pegged tokens minted
    /// @param stabilityPool Address of the StabilityPool
    /// @param deposited Amount deposited into StabilityPool
    event WrappedCollateralZappedToStabilityPool(
        address indexed user,
        address indexed minter,
        address indexed receiver,
        uint256 wrappedCollateralAmount,
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

        // Verify that wrapped collateral matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (WRAPPED_COLLATERAL_ASSET != expectedCollateral) {
            revert IZapErrors.CollateralMismatch(expectedCollateral, WRAPPED_COLLATERAL_ASSET);
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

    /// @notice Zap base asset into pegged tokens in one transaction
    /// @dev Flow: base asset → wrapped collateral → Minter mint pegged
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapBaseAssetToPegged(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    )
        external
        nonReentrant
        returns (uint256 peggedOut)
    {
        _requireSupportedAsset(BASE_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) =
            _zapToPegged(BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver, minPeggedOut);

        emit BaseAssetZappedToPegged(
            _msgSender(), MINTER, receiver, baseAssetAmount, wrappedCollateralAmount, peggedOut
        );
    }

    /// @notice Zap base asset into leveraged tokens in one transaction
    /// @dev Flow: base asset → wrapped collateral → Minter mint leveraged
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapBaseAssetToLeveraged(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    )
        external
        nonReentrant
        returns (uint256 leveragedOut)
    {
        _requireSupportedAsset(BASE_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) =
            _zapToLeveraged(BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver, minLeveragedOut);

        emit BaseAssetZappedToLeverage(
            _msgSender(), MINTER, receiver, baseAssetAmount, wrappedCollateralAmount, leveragedOut
        );
    }

    /// @notice Zap collateral into pegged tokens in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint pegged
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapCollateralToPegged(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    )
        external
        nonReentrant
        returns (uint256 peggedOut)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver, minPeggedOut
        );

        emit CollateralZappedToPegged(
            _msgSender(), MINTER, receiver, collateralAmount, wrappedCollateralAmount, peggedOut
        );
    }

    /// @notice Zap collateral into leveraged tokens in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint leveraged
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapCollateralToLeveraged(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    )
        external
        nonReentrant
        returns (uint256 leveragedOut)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver, minLeveragedOut
        );

        emit CollateralZappedToLeveraged(
            _msgSender(), MINTER, receiver, collateralAmount, wrappedCollateralAmount, leveragedOut
        );
    }

    /// @notice Zap base asset into StabilityPool in one transaction
    /// @dev Flow: base asset → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromWrappedCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromWrappedCollateral with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapBaseAssetToStabilityPool(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _requireSupportedAsset(BASE_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            BASE_ASSET,
            baseAssetAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit BaseAssetZappedToStabilityPool(
            _msgSender(),
            MINTER,
            receiver,
            baseAssetAmount,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    /// @notice Zap collateral into StabilityPool in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromWrappedCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromWrappedCollateral with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapCollateralToStabilityPool(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit CollateralZappedToStabilityPool(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    /// @notice Zap wrapped collateral into StabilityPool in one transaction
    /// @dev Flow: wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromWrappedCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param wrappedCollateralAmount Amount of wrapped collateral to zap
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromWrappedCollateral with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Minimum amount to deposit into StabilityPool (required by StabilityPool interface, but since stability pools don't incur fees, should equal peggedOut minus small rounding buffer ~0.1%)
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapWrappedCollateralToStabilityPool(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            WRAPPED_COLLATERAL_ASSET,
            wrappedCollateralAmount,
            0,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit WrappedCollateralZappedToStabilityPool(
            _msgSender(), MINTER, receiver, wrappedCollateralAmount, peggedOut, stabilityPool, deposited
        );
    }

    // ============ Permit-Based Functions ============

    /// @notice Zap base asset into pegged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit base asset → base asset → wrapped collateral → Minter mint pegged
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    function zapBaseAssetToPeggedWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut) {
        _requireSupportedAsset(BASE_ASSET);
        _permitBaseAsset(baseAssetAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver, minPeggedOut
        );

        emit BaseAssetZappedToPegged(
            _msgSender(), MINTER, receiver, baseAssetAmount, wrappedCollateralAmount, peggedOut
        );
    }

    /// @notice Zap base asset into leveraged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit base asset → base asset → wrapped collateral → Minter mint leveraged
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapBaseAssetToLeveragedWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 leveragedOut) {
        _requireSupportedAsset(BASE_ASSET);
        _permitBaseAsset(baseAssetAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver, minLeveragedOut
        );

        emit BaseAssetZappedToLeverage(
            _msgSender(), MINTER, receiver, baseAssetAmount, wrappedCollateralAmount, leveragedOut
        );
    }

    /// @notice Zap collateral into pegged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Minter mint pegged
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return peggedOut Amount of pegged tokens minted
    function zapCollateralToPeggedWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        _permitCollateral(collateralAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver, minPeggedOut
        );

        emit CollateralZappedToPegged(
            _msgSender(), MINTER, receiver, collateralAmount, wrappedCollateralAmount, peggedOut
        );
    }

    /// @notice Zap collateral into leveraged tokens using permit (single transaction, no approval needed)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Minter mint leveraged
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapCollateralToLeveragedWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 leveragedOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        _permitCollateral(collateralAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver, minLeveragedOut
        );

        emit CollateralZappedToLeveraged(
            _msgSender(), MINTER, receiver, collateralAmount, wrappedCollateralAmount, leveragedOut
        );
    }

    /// @notice Zap base asset into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit base asset → base asset → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
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
    function zapBaseAssetToStabilityPoolWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _requireSupportedAsset(BASE_ASSET);
        _permitBaseAsset(baseAssetAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            BASE_ASSET,
            baseAssetAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit BaseAssetZappedToStabilityPool(
            _msgSender(),
            MINTER,
            receiver,
            baseAssetAmount,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    /// @notice Zap collateral into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
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
    function zapCollateralToStabilityPoolWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        _permitCollateral(collateralAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit CollateralZappedToStabilityPool(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    /// @notice Zap wrapped collateral into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit wrapped collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @param wrappedCollateralAmount Amount of wrapped collateral to zap
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
    function zapWrappedCollateralToStabilityPoolWithPermit(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _permitWrappedCollateral(wrappedCollateralAmount, deadline, v, r, s);
        (wrappedCollateralAmount, peggedOut, deposited) = _zapToStabilityPoolFromToken(
            WRAPPED_COLLATERAL_ASSET,
            wrappedCollateralAmount,
            0,
            receiver,
            minPeggedOut,
            stabilityPool,
            minStabilityPoolOut
        );

        emit WrappedCollateralZappedToStabilityPool(
            _msgSender(), MINTER, receiver, wrappedCollateralAmount, peggedOut, stabilityPool, deposited
        );
    }

    // ============ Internal Helper Functions ============

    function _requireSupportedAsset(address asset) internal view {
        if (block.chainid != 1 && asset == address(0)) {
            revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
        }
    }

    /// @notice Helper to handle base asset permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitBaseAsset(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(BASE_ASSET).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Helper to handle collateral permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitCollateral(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(COLLATERAL_ASSET).permit(
            _msgSender(), address(this), amount, deadline, v, r, s
        );
    }

    /// @notice Helper to handle wrapped collateral permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitWrappedCollateral(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        IERC20Permit(WRAPPED_COLLATERAL_ASSET).permit(
            _msgSender(), address(this), amount, deadline, v, r, s
        );
    }

    /// @notice Convert base asset or collateral to wrapped collateral via diamond contract
    /// @param tokenIn Token to convert (base asset or collateral)
    /// @param amountIn Amount of tokenIn to convert
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    function _convertToWrappedCollateral(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut
    )
        internal
        returns (uint256 wrappedCollateralAmount)
    {
        // Pull token from user
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        // tokenIn → wrapped collateral via diamond contract
        IERC20 token = IERC20(tokenIn);
        _safeApprove(token, FXUSD_DIAMOND, amountIn);

        bytes memory swapData = abi.encodeWithSelector(
            FxSAVEConstants.CONVERT_SELECTOR, tokenIn, amountIn, minWrappedCollateralOut, ""
        );

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: tokenIn,
            amount: amountIn,
            target: FXUSD_SWAP_ROUTER,
            data: swapData,
            minOut: minWrappedCollateralOut,
            signature: ""
        });

        uint256 wrappedCollateralBefore =
            IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave{value: 0}(params, tokenIn, 0, address(this));
        uint256 wrappedCollateralAfter =
            IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        wrappedCollateralAmount = wrappedCollateralAfter - wrappedCollateralBefore;
        if (wrappedCollateralAmount == 0) revert IZapErrors.NoWrappedCollateralReceived();
        if (wrappedCollateralAmount < minWrappedCollateralOut) revert IZapErrors.SlippageExceeded();
    }

    /// @notice Zap a token into pegged tokens and reset allowances
    /// @param tokenIn Token to zap (base asset or collateral)
    /// @param amountIn Amount of tokenIn to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Address receiving pegged tokens
    /// @param minPeggedOut Minimum pegged tokens to receive
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    /// @return peggedOut Amount of pegged tokens minted
    function _zapToPegged(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 peggedOut) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        wrappedCollateralAmount =
            _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        peggedOut = _mintPeggedToken(wrappedCollateralAmount, receiver, minPeggedOut);
        _resetAllowances();
    }

    /// @notice Zap a token into leveraged tokens and reset allowances
    /// @param tokenIn Token to zap (base asset or collateral)
    /// @param amountIn Amount of tokenIn to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Address receiving leveraged tokens
    /// @param minLeveragedOut Minimum leveraged tokens to receive
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    /// @return leveragedOut Amount of leveraged tokens minted
    function _zapToLeveraged(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 leveragedOut) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        wrappedCollateralAmount =
            _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        leveragedOut = _mintLeveragedToken(wrappedCollateralAmount, receiver, minLeveragedOut);
        _resetAllowances();
    }

    /// @notice Zap a token into StabilityPool via minted pegged tokens
    /// @param tokenIn Token to zap (base asset, collateral, or wrapped collateral)
    /// @param amountIn Amount of tokenIn to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Address receiving StabilityPool deposit
    /// @param minPeggedOut Minimum pegged tokens to receive
    /// @param stabilityPool StabilityPool address
    /// @param minStabilityPoolOut Minimum StabilityPool deposit amount
    /// @return wrappedCollateralAmount Amount of wrapped collateral used to mint pegged tokens
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function _zapToStabilityPoolFromToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) internal returns (uint256 wrappedCollateralAmount, uint256 peggedOut, uint256 deposited) {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();

        if (tokenIn == WRAPPED_COLLATERAL_ASSET) {
            IERC20(WRAPPED_COLLATERAL_ASSET).safeTransferFrom(
                _msgSender(), address(this), amountIn
            );
            wrappedCollateralAmount = amountIn;
            if (wrappedCollateralAmount < minWrappedCollateralOut) {
                revert IZapErrors.SlippageExceeded();
            }
        } else {
            wrappedCollateralAmount =
                _convertToWrappedCollateral(tokenIn, amountIn, minWrappedCollateralOut);
        }

        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wrappedCollateralAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);
        _resetAllowances();
    }

    /// @notice Mint pegged tokens and validate the result
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function _mintPeggedToken(uint256 wrappedCollateralAmount, address receiver, uint256 minPeggedOut)
        internal
        returns (uint256 peggedOut)
    {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        uint256 peggedBalanceBefore = IERC20(peggedToken).balanceOf(receiver);
        IERC20(WRAPPED_COLLATERAL_ASSET).forceApprove(MINTER, wrappedCollateralAmount);
        peggedOut = IMinter(MINTER).mintPeggedToken(wrappedCollateralAmount, receiver, minPeggedOut);

        // Validate that tokens were actually minted
        uint256 peggedBalanceAfter = IERC20(peggedToken).balanceOf(receiver);
        if (peggedBalanceAfter - peggedBalanceBefore != peggedOut || peggedOut == 0) {
            revert IZapErrors.MintFailed();
        }
    }

    /// @notice Mint leveraged tokens and validate the result
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function _mintLeveragedToken(
        uint256 wrappedCollateralAmount,
        address receiver,
        uint256 minLeveragedOut
    )
        internal
        returns (uint256 leveragedOut)
    {
        address leveragedToken = IMinter(MINTER).LEVERAGED_TOKEN();
        uint256 leveragedBalanceBefore = IERC20(leveragedToken).balanceOf(receiver);
        IERC20(WRAPPED_COLLATERAL_ASSET).forceApprove(MINTER, wrappedCollateralAmount);
        leveragedOut = IMinter(MINTER).mintLeveragedToken(wrappedCollateralAmount, receiver, minLeveragedOut);

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
        IERC20(BASE_ASSET).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(COLLATERAL_ASSET).forceApprove(FXUSD_DIAMOND, 0);
        IERC20(WRAPPED_COLLATERAL_ASSET).forceApprove(MINTER, 0);
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

    /// @notice Preview wrapped collateral output from a base asset amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewWrappedCollateralFromBase(uint256)
        external
        pure
        returns (uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview wrapped collateral output from a collateral amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewWrappedCollateralFromCollateral(uint256)
        external
        pure
        returns (uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected pegged token output from a base asset amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewPeggedFromBase(uint256)
        external
        pure
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected leveraged token output from a base asset amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewLeveragedFromBase(uint256)
        external
        pure
        returns (uint256 leveragedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected pegged token output from a collateral amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewPeggedFromCollateral(uint256)
        external
        pure
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected leveraged token output from a collateral amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewLeveragedFromCollateral(uint256)
        external
        pure
        returns (uint256 leveragedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected StabilityPool deposit from a base asset zap
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewStabilityPoolFromBase(uint256)
        external
        pure
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected StabilityPool deposit from a collateral zap
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewStabilityPoolFromCollateral(uint256)
        external
        pure
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.FunctionNotFound();
    }

    /// @notice Preview the expected pegged token output from a wrapped collateral amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    function previewPeggedFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        view
        returns (uint256 peggedOut)
    {
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected leveraged token output from a wrapped collateral amount
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    function previewLeveragedFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        view
        returns (uint256 leveragedOut)
    {
        (,,,, leveragedOut,,) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a wrapped collateral amount
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    function previewStabilityPoolFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        view
        returns (uint256 peggedOut)
    {
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
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

    function rescueNativeAsset() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function rescueToken(address token) external onlyOwner {
        if (
            token == BASE_ASSET || token == COLLATERAL_ASSET || token == WRAPPED_COLLATERAL_ASSET
                || token == MINTER
        ) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // ============ Safety Functions ============

    receive() external payable {
        // Allow contract to receive base asset for recovery
    }

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}

