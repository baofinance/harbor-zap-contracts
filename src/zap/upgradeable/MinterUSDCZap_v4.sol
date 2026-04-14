// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "src/utils/upgradeable/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {IMinterZapV4BaseErc20} from "src/interfaces/IMinterZapV4BaseErc20.sol";
import {IMinterZapV4Common} from "src/interfaces/IMinterZapV4Common.sol";
import {MinterZapBase_v1} from "src/zap/upgradeable/base/MinterZapBase_v1.sol";
import {FxUSDZapNetworkConfig} from "src/zap/upgradeable/config/FxUSDZapNetworkConfig.sol";
import {FxUSDZapBase_v1} from "src/zap/upgradeable/asset/FxUSDZapBase_v1.sol";

/// @title MinterUSDCZapV4
/// @notice One-click zapper for minting pegged or leveraged tokens with base asset or collateral via wrapped collateral
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: base asset/collateral → wrapped collateral → Minter mint
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract MinterUSDCZap_v4 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransient,
    BaoOwnable,
    MinterZapBase_v1,
    FxUSDZapBase_v1,
    IMinterZapV4Common,
    IMinterZapV4BaseErc20
{
    using SafeERC20 for IERC20;

    // ============ Network config (immutables) ============

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable BASE_ASSET;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable COLLATERAL_ASSET;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_ASSET;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable COLLATERAL_MANAGER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable SWAP_ROUTER;

    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bytes4 public immutable CONVERT_SELECTOR;

    // ============ Immutables ============

    /// @notice Minter contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    // ============ Configurable ============

    /// @notice Mapping of allowed stability pool addresses
    mapping(address => bool) public allowedStabilityPools;

    /// @dev Reserved slots for future storage variables. Shrink the array when appending new state (OZ upgradeable pattern).
    uint256[50] private __gap;

    // ============ Events ============
    /// @dev Zap lifecycle events (`BaseAssetZappedTo*`, etc.) live on `MinterZapBase_v1`.

    event StabilityPoolAllowlistUpdated(address indexed stabilityPool, bool allowed);
    event Upgraded(address indexed implementation);

    // ============ Constructor ============

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_) {
        _disableInitializers();

        if (minter_ == address(0)) revert IZapErrors.ZeroAddress();

        FxUSDZapNetworkConfig.Config memory cfg = FxUSDZapNetworkConfig.load(block.chainid);
        if (cfg.fxsave == address(0)) revert IZapErrors.AssetNotSupportedOnChain(address(0), block.chainid);

        BASE_ASSET = cfg.usdc;
        COLLATERAL_ASSET = cfg.fxusd;
        WRAPPED_COLLATERAL_ASSET = cfg.fxsave;
        COLLATERAL_MANAGER = cfg.collateralManager;
        SWAP_ROUTER = cfg.swapRouter;
        CONVERT_SELECTOR = cfg.convertSelector;

        // Verify that wrapped collateral matches the Minter wrapped collateral token
        address expectedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        if (WRAPPED_COLLATERAL_ASSET != expectedCollateral) {
            revert IZapErrors.WrappedCollateralMismatch(expectedCollateral, WRAPPED_COLLATERAL_ASSET);
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

        emit BaseAssetZappedToLeveraged(
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

        emit BaseAssetZappedToLeveraged(
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

    /// @dev Only tokens this zap is built for (immutables from `FxUSDZapNetworkConfig` + minter wrapped-token check).
    function _requireSupportedAsset(address asset) internal view override {
        if (asset == WRAPPED_COLLATERAL_ASSET) return;
        if (asset == BASE_ASSET) return;
        if (asset == COLLATERAL_ASSET) return;
        revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
    }

    function _minterAddress() internal view override returns (address) {
        return MINTER;
    }

    function _wrappedCollateralAssetAddress() internal view override returns (address) {
        return WRAPPED_COLLATERAL_ASSET;
    }

    function _isStabilityPoolAllowed(address stabilityPool) internal view override returns (bool) {
        return allowedStabilityPools[stabilityPool];
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
        override
        returns (uint256 wrappedCollateralAmount)
    {
        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        wrappedCollateralAmount = _convertHeldTokenToWrappedCollateral(
            COLLATERAL_MANAGER,
            SWAP_ROUTER,
            WRAPPED_COLLATERAL_ASSET,
            CONVERT_SELECTOR,
            tokenIn,
            amountIn,
            minWrappedCollateralOut
        );
    }

    /// @notice Reset token allowances to zero
    function _resetAllowances() internal override {
        _safeApprove(IERC20(BASE_ASSET), COLLATERAL_MANAGER, 0);
        _safeApprove(IERC20(COLLATERAL_ASSET), COLLATERAL_MANAGER, 0);
        IERC20(WRAPPED_COLLATERAL_ASSET).forceApprove(MINTER, 0);
    }

    // ============ View Functions (Preview) ============

    /// @notice Preview fxSAVE from USDC via ERC4626 `convertToShares` (see `FxUSDZapBase_v1` for peg assumptions).
    function previewWrappedCollateralFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewFxSaveSharesFromUsdcAssumedPeg(
            WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, baseAssetAmount
        );
    }

    /// @notice Preview fxSAVE from fxUSD via `convertToShares`.
    function previewWrappedCollateralFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount =
            _previewFxSaveSharesFromFxUsd(WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, collateralAmount);
    }

    /// @notice Preview pegged mint from USDC (wrapped leg uses fxSAVE `convertToShares`; peg leg uses minter dry-run).
    function previewPeggedFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewFxSaveSharesFromUsdcAssumedPeg(
            WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, baseAssetAmount
        );
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview leveraged mint from USDC.
    function previewLeveragedFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 leveragedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewFxSaveSharesFromUsdcAssumedPeg(
            WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, baseAssetAmount
        );
        (,,,, leveragedOut,,) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview pegged mint from fxUSD collateral.
    function previewPeggedFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount =
            _previewFxSaveSharesFromFxUsd(WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, collateralAmount);
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview leveraged mint from fxUSD collateral.
    function previewLeveragedFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 leveragedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount =
            _previewFxSaveSharesFromFxUsd(WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, collateralAmount);
        (,,,, leveragedOut,,) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview StabilityPool path from USDC (pegged mint dry-run on estimated fxSAVE).
    function previewStabilityPoolFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewFxSaveSharesFromUsdcAssumedPeg(
            WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, baseAssetAmount
        );
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview StabilityPool path from fxUSD.
    function previewStabilityPoolFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 peggedOut, uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount =
            _previewFxSaveSharesFromFxUsd(WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, collateralAmount);
        (,,, peggedOut,,) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
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

