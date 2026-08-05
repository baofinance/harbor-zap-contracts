// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWstETHView} from "@harborzap/interfaces/IWstETH.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {IMinterZapV1BaseNative} from "@harborzap/interfaces/IMinterZapV1BaseNative.sol";
import {IMinterZapV1Common} from "@harborzap/interfaces/IMinterZapV1Common.sol";
import {StETHZapNetworkConfig} from "@harborzap/zap/upgradeable/config/StETHZapNetworkConfig.sol";
import {MinterZapBase_v1} from "@harborzap/zap/upgradeable/base/MinterZapBase_v1.sol";
import {ZapIntake} from "@harborzap/zap/upgradeable/base/ZapIntake.sol";
import {StETHZapBase_v1} from "@harborzap/zap/upgradeable/asset/StETHZapBase_v1.sol";

/// @title MinterETHZapV1
/// @notice One-click zapper for minting pegged or leveraged tokens with base asset or collateral via wrapped collateral
/// @dev Enables users to mint pegged or leveraged tokens in a single transaction
/// @dev Flow: base asset → collateral → wrapped collateral → Minter mint
/// @dev Flow: collateral → wrapped collateral → Minter mint
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-capwords
contract MinterETHZap_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    HarborOwnable,
    TokenHolder_v2,
    MinterZapBase_v1,
    StETHZapBase_v1,
    IMinterZapV1Common,
    IMinterZapV1BaseNative
{
    using SafeERC20 for IERC20;

    // ============ Network Config (immutables) ============

    /// @notice Default referral address for Lido deposits
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable DEFAULT_REFERRAL;
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
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool public immutable SUPPORTS_BASE_ASSET;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool public immutable SUPPORTS_COLLATERAL_ASSET;

    // ============ Immutables ============

    /// @notice Minter contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable MINTER;

    // ============ Storage (ERC-7201) ============

    /// @custom:storage-location erc7201:harborzap.storage.MinterETHZap_v1
    // cast index-erc7201 harborzap.storage.MinterETHZap_v1
    bytes32 private constant _MINTER_ETH_ZAP_STORAGE =
        0xb8febf9413325832509ac1da4e1a34c95927e46ad93e1b6e15e5e36c6f7a1400;

    struct MinterETHZapStorage {
        /// @notice Mapping of allowed stability pool addresses
        mapping(address => bool) allowedStabilityPools;
    }

    function _getMinterETHZapStorage() private pure returns (MinterETHZapStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _MINTER_ETH_ZAP_STORAGE
        }
    }

    // ============ Events ============
    /// @dev Zap lifecycle events (`BaseAssetZappedTo*`, etc.) live on `MinterZapBase_v1`.

    event StabilityPoolAllowlistUpdated(address indexed stabilityPool, bool allowed);
    // ============ Constructor ============

    /// @notice In UUPS proxies the constructor is used only to stop the implementation being initialized to any version
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address minter_) {
        _disableInitializers();

        if (minter_ == address(0)) revert IZapErrors.ZeroAddress();
        StETHZapNetworkConfig.Config memory cfg = StETHZapNetworkConfig.load(block.chainid);
        DEFAULT_REFERRAL = cfg.defaultReferral;
        BASE_ASSET = cfg.baseAsset;
        COLLATERAL_ASSET = cfg.collateralAsset;
        WRAPPED_COLLATERAL_ASSET = cfg.wrappedCollateralAsset;
        COLLATERAL_MANAGER = cfg.collateralManager;
        SWAP_ROUTER = cfg.swapRouter;
        CONVERT_SELECTOR = cfg.convertSelector;
        SUPPORTS_BASE_ASSET = cfg.supportsBaseAsset;
        SUPPORTS_COLLATERAL_ASSET = cfg.supportsCollateralAsset;
        if (WRAPPED_COLLATERAL_ASSET == address(0))
            revert IZapErrors.AssetNotSupportedOnChain(address(0), block.chainid);

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
        __Context_init();
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    // ============ External Functions ============

    /// @notice Zap native base asset (ETH) into pegged tokens in one transaction
    /// @dev Flow: ETH → collateral → wrapped collateral → Minter mint pegged
    /// @dev Use previewPeggedFromBase() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param minWrappedCollateralOut Minimum wrapped collateral from ETH→stETH→wrap; 0 skips slippage check on wrap leg
    /// @param receiver Address that will receive the pegged tokens
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @return peggedOut Amount of pegged tokens minted
    function zapNativeAssetToPegged(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut
    ) external payable nonReentrant returns (uint256 peggedOut) {
        _requireSupportedAsset(BASE_ASSET);
        uint256 baseAssetAmount = msg.value;
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            BASE_ASSET,
            baseAssetAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut
        );

        emit BaseAssetZappedToPegged(
            _msgSender(),
            MINTER,
            receiver,
            baseAssetAmount,
            wrappedCollateralAmount,
            peggedOut
        );
    }

    /// @notice Zap native base asset (ETH) into leveraged tokens in one transaction
    /// @dev Flow: ETH → collateral → wrapped collateral → Minter mint leveraged
    /// @dev Use previewLeveragedFromBase() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param minWrappedCollateralOut Minimum wrapped collateral from ETH→stETH→wrap; 0 skips slippage check on wrap leg
    /// @param receiver Address that will receive the leveraged tokens
    /// @param minLeveragedOut Minimum amount of leveraged tokens to receive
    /// @return leveragedOut Amount of leveraged tokens minted
    function zapNativeAssetToLeveraged(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minLeveragedOut
    ) external payable nonReentrant returns (uint256 leveragedOut) {
        _requireSupportedAsset(BASE_ASSET);
        uint256 baseAssetAmount = msg.value;
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            BASE_ASSET,
            baseAssetAmount,
            minWrappedCollateralOut,
            receiver,
            minLeveragedOut
        );

        emit BaseAssetZappedToLeveraged(
            _msgSender(),
            MINTER,
            receiver,
            baseAssetAmount,
            wrappedCollateralAmount,
            leveragedOut
        );
    }

    /// @notice Zap collateral into pegged tokens in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint pegged
    /// @dev Use previewPeggedFromCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
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
    ) external nonReentrant returns (uint256 peggedOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut
        );

        emit CollateralZappedToPegged(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            peggedOut
        );
    }

    /// @notice Zap collateral into leveraged tokens in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint leveraged
    /// @dev Use previewLeveragedFromCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
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
    ) external nonReentrant returns (uint256 leveragedOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minLeveragedOut
        );

        emit CollateralZappedToLeveraged(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            leveragedOut
        );
    }

    /// @notice Zap native base asset (ETH) into StabilityPool in one transaction
    /// @dev Flow: ETH → collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromBase() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param minWrappedCollateralOut Minimum wrapped collateral from ETH→stETH→wrap; 0 skips slippage check on wrap leg
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromBase with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Forwarded to the pool's own `deposit` min-out check. The zap independently requires the pool to credit exactly 1:1 (no fees/rounding) and reverts with `DepositFailed` otherwise, so `minPeggedOut` already bounds the outcome; passing `minPeggedOut` (or 0) is sufficient.
    /// @return peggedOut Amount of pegged tokens minted
    /// @return deposited Amount deposited into StabilityPool
    function zapNativeAssetToStabilityPool(
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 minPeggedOut,
        address stabilityPool,
        uint256 minStabilityPoolOut
    ) external payable nonReentrant returns (uint256 peggedOut, uint256 deposited) {
        _requireSupportedAsset(BASE_ASSET);
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();

        uint256 baseAssetAmount = msg.value;
        uint256 wrappedCollateralAmount = _convertBaseAssetToWrappedCollateral(baseAssetAmount);
        if (wrappedCollateralAmount < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(wrappedCollateralAmount, minWrappedCollateralOut);
        }

        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        peggedOut = _mintPeggedToken(wrappedCollateralAmount, address(this), minPeggedOut);
        deposited = _depositToStabilityPool(peggedToken, stabilityPool, peggedOut, receiver, minStabilityPoolOut);

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
        _resetAllowances();
    }

    /// @notice Zap collateral into StabilityPool in one transaction
    /// @dev Flow: collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @dev Use previewStabilityPoolFromCollateral() to calculate expected output, then apply a slippage buffer (0.5-1%)
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive (use previewStabilityPoolFromCollateral with slippage buffer)
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Forwarded to the pool's own `deposit` min-out check. The zap independently requires the pool to credit exactly 1:1 (no fees/rounding) and reverts with `DepositFailed` otherwise, so `minPeggedOut` already bounds the outcome; passing `minPeggedOut` (or 0) is sufficient.
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
    /// @param minStabilityPoolOut Forwarded to the pool's own `deposit` min-out check. The zap independently requires the pool to credit exactly 1:1 (no fees/rounding) and reverts with `DepositFailed` otherwise, so `minPeggedOut` already bounds the outcome; passing `minPeggedOut` (or 0) is sufficient.
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
            _msgSender(),
            MINTER,
            receiver,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    // ============ Permit-Based Functions ============

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
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        _permitCollateral(COLLATERAL_ASSET, _msgSender(), collateralAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, peggedOut) = _zapToPegged(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minPeggedOut
        );

        emit CollateralZappedToPegged(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            peggedOut
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
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        _permitCollateral(COLLATERAL_ASSET, _msgSender(), collateralAmount, deadline, v, r, s);
        uint256 wrappedCollateralAmount;
        (wrappedCollateralAmount, leveragedOut) = _zapToLeveraged(
            COLLATERAL_ASSET,
            collateralAmount,
            minWrappedCollateralOut,
            receiver,
            minLeveragedOut
        );

        emit CollateralZappedToLeveraged(
            _msgSender(),
            MINTER,
            receiver,
            collateralAmount,
            wrappedCollateralAmount,
            leveragedOut
        );
    }

    /// @notice Zap collateral into StabilityPool using permit (single transaction, no approval needed)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Minter mint pegged → StabilityPool deposit
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the StabilityPool deposit
    /// @param minPeggedOut Minimum amount of pegged tokens to receive
    /// @param stabilityPool StabilityPool address to deposit pegged tokens into
    /// @param minStabilityPoolOut Forwarded to the pool's own `deposit` min-out check. The zap independently requires the pool to credit exactly 1:1 (no fees/rounding) and reverts with `DepositFailed` otherwise, so `minPeggedOut` already bounds the outcome; passing `minPeggedOut` (or 0) is sufficient.
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
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();

        _permitCollateral(COLLATERAL_ASSET, _msgSender(), collateralAmount, deadline, v, r, s);
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
    /// @param minStabilityPoolOut Forwarded to the pool's own `deposit` min-out check. The zap independently requires the pool to credit exactly 1:1 (no fees/rounding) and reverts with `DepositFailed` otherwise, so `minPeggedOut` already bounds the outcome; passing `minPeggedOut` (or 0) is sufficient.
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
            _msgSender(),
            MINTER,
            receiver,
            wrappedCollateralAmount,
            peggedOut,
            stabilityPool,
            deposited
        );
    }

    // ============ Internal Helper Functions ============

    function _requireSupportedAsset(address asset) internal view override {
        if (asset == WRAPPED_COLLATERAL_ASSET) return;
        if (asset == BASE_ASSET && SUPPORTS_BASE_ASSET) return;
        if (asset == COLLATERAL_ASSET && SUPPORTS_COLLATERAL_ASSET) return;
        revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
    }

    function _minterAddress() internal view override returns (address) {
        return MINTER;
    }

    function _wrappedCollateralAssetAddress() internal view override returns (address) {
        return WRAPPED_COLLATERAL_ASSET;
    }

    function _isStabilityPoolAllowed(address stabilityPool) internal view override returns (bool) {
        return _getMinterETHZapStorage().allowedStabilityPools[stabilityPool];
    }

    /// @notice Helper to handle wrapped collateral permit
    /// @param amount Amount to permit
    /// @param deadline Permit deadline
    /// @param v Permit signature v
    /// @param r Permit signature r
    /// @param s Permit signature s
    function _permitWrappedCollateral(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        ZapIntake.tryPermit(IERC20Permit(WRAPPED_COLLATERAL_ASSET), _msgSender(), amount, deadline, v, r, s);
    }

    /// @notice Convert base asset to wrapped collateral via collateral
    /// @param baseAssetAmount Amount of base asset to convert
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    function _convertBaseAssetToWrappedCollateral(
        uint256 baseAssetAmount
    ) internal returns (uint256 wrappedCollateralAmount) {
        uint256 collateralReceived = _convertBaseAssetToCollateral(COLLATERAL_ASSET, DEFAULT_REFERRAL, baseAssetAmount);
        wrappedCollateralAmount = _wrapCollateralToWrappedCollateral(
            COLLATERAL_ASSET,
            WRAPPED_COLLATERAL_ASSET,
            collateralReceived
        );
    }

    /// @notice Convert collateral to wrapped collateral
    /// @param collateralAmount Amount of collateral to convert
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    function _convertCollateralToWrappedCollateral(
        uint256 collateralAmount
    ) internal returns (uint256 wrappedCollateralAmount) {
        uint256 baseline = IERC20(COLLATERAL_ASSET).balanceOf(address(this));
        uint256 received = ZapIntake.pullMeasured(IERC20(COLLATERAL_ASSET), _msgSender(), collateralAmount);
        wrappedCollateralAmount = _wrapCollateralToWrappedCollateral(
            COLLATERAL_ASSET,
            WRAPPED_COLLATERAL_ASSET,
            received
        );
        ZapIntake.refundLeftoverAbove(IERC20(COLLATERAL_ASSET), baseline, _msgSender());
    }

    /// @notice Convert an input token to wrapped collateral (native ETH when `tokenIn == BASE_ASSET`)
    /// @param tokenIn `BASE_ASSET` or `COLLATERAL_ASSET`
    /// @param amountIn Amount of `tokenIn` (ETH already credited to this contract when `tokenIn == BASE_ASSET`)
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage; 0 skips the check)
    /// @return wrappedCollateralAmount Amount of wrapped collateral received
    function _convertToWrappedCollateral(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut
    ) internal override returns (uint256 wrappedCollateralAmount) {
        if (tokenIn == BASE_ASSET) {
            wrappedCollateralAmount = _convertBaseAssetToWrappedCollateral(amountIn);
        } else if (tokenIn == COLLATERAL_ASSET) {
            wrappedCollateralAmount = _convertCollateralToWrappedCollateral(amountIn);
        } else {
            revert IZapErrors.ZapTokenInNotSupported(tokenIn);
        }
        if (wrappedCollateralAmount < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(wrappedCollateralAmount, minWrappedCollateralOut);
        }
    }

    /// @notice Reset token allowances to zero
    function _resetAllowances() internal override {
        IERC20(COLLATERAL_ASSET).forceApprove(WRAPPED_COLLATERAL_ASSET, 0);
        IERC20(WRAPPED_COLLATERAL_ASSET).forceApprove(MINTER, 0);
    }

    // ============ View Functions (Preview) ============

    /// @notice Internal helper to preview base asset → wrapped collateral conversion
    /// @param baseAssetAmount Amount of base asset
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function _previewWrappedCollateralFromBase(
        uint256 baseAssetAmount
    ) internal view returns (uint256 wrappedCollateralAmount) {
        wrappedCollateralAmount = _estimateWrappedCollateralFromBase(
            COLLATERAL_ASSET,
            WRAPPED_COLLATERAL_ASSET,
            baseAssetAmount
        );
    }

    /// @notice Preview the expected wrapped collateral output from a base asset amount
    /// @param baseAssetAmount Amount of base asset
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewWrappedCollateralFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewWrappedCollateralFromBase(baseAssetAmount);
    }

    /// @notice Preview the expected wrapped collateral output from a collateral amount
    /// @param collateralAmount Amount of collateral
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewWrappedCollateralFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETHView(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
    }

    /// @notice Preview the expected pegged token output from a base asset amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param baseAssetAmount Amount of base asset to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewPeggedFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewWrappedCollateralFromBase(baseAssetAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected leveraged token output from a base asset amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param baseAssetAmount Amount of base asset to zap
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewLeveragedFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 leveragedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewWrappedCollateralFromBase(baseAssetAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected pegged token output from a collateral amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param collateralAmount Amount of collateral to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewPeggedFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETHView(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected leveraged token output from a collateral amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param collateralAmount Amount of collateral to zap
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewLeveragedFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 leveragedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETHView(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a base asset zap
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param baseAssetAmount Amount of base asset to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewStabilityPoolFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewWrappedCollateralFromBase(baseAssetAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a collateral zap
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param collateralAmount Amount of collateral to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewStabilityPoolFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 peggedOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETHView(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected pegged token output from a wrapped collateral amount
    /// @dev Uses Minter's dry run function to get accurate output accounting for fees/incentives
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @return peggedOut Expected amount of pegged tokens that will be minted
    function previewPeggedFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 peggedOut) {
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected leveraged token output from a wrapped collateral amount
    /// @param wrappedCollateralAmount Amount of wrapped collateral to use for minting
    /// @return leveragedOut Expected amount of leveraged tokens that will be minted
    function previewLeveragedFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 leveragedOut) {
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , , leveragedOut, , ) = IMinter(MINTER).mintLeveragedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Preview the expected StabilityPool deposit from a wrapped collateral zap
    /// @dev Returns the expected pegged tokens that will be minted and deposited into StabilityPool
    /// @dev Use this to set minStabilityPoolOut with a slippage buffer (0.5-1%)
    /// @param wrappedCollateralAmount Amount of wrapped collateral to zap
    /// @return peggedOut Expected amount of pegged tokens that will be minted (and deposited)
    function previewStabilityPoolFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external view returns (uint256 peggedOut) {
        // slither-disable-next-line unused-return — dry-run returns extra fee/incentive fields unused by preview
        (, , , peggedOut, , ) = IMinter(MINTER).mintPeggedTokenDryRun(wrappedCollateralAmount);
    }

    /// @notice Human-readable zap name based on the pegged token
    function zapName() external view returns (string memory) {
        address peggedToken = IMinter(MINTER).PEGGED_TOKEN();
        return string(abi.encodePacked("Minter zap ", IERC20Metadata(peggedToken).name()));
    }

    // ============ Owner Functions ============

    /// @inheritdoc IMinterZapV1BaseNative
    function referral() external view returns (address) {
        return DEFAULT_REFERRAL;
    }

    /// @notice Whether a stability pool is allowlisted for zap deposits
    function allowedStabilityPools(address stabilityPool) external view returns (bool) {
        return _getMinterETHZapStorage().allowedStabilityPools[stabilityPool];
    }

    /// @notice Set the allowed status of a stability pool
    /// @param stabilityPool Address of the stability pool
    /// @param allowed Whether the stability pool is allowed
    function setStabilityPoolAllowed(address stabilityPool, bool allowed) external onlyOwner {
        if (stabilityPool == address(0)) revert IZapErrors.ZeroAddress();
        _getMinterETHZapStorage().allowedStabilityPools[stabilityPool] = allowed;
        emit StabilityPoolAllowlistUpdated(stabilityPool, allowed);
    }

    function rescueNativeAsset() external onlyOwner {
        address to = owner();
        uint256 amount = address(this).balance;
        // slither-disable-next-line low-level-calls — intentional: `.transfer` can brick contract owners
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert IZapErrors.NativeTransferFailed();
    }

    function rescueToken(address token) external onlyOwner {
        _sweep(token, IERC20(token).balanceOf(address(this)), owner());
    }

    function _sweep(address token, uint256 amount, address receiver) internal override {
        if (token == COLLATERAL_ASSET || token == WRAPPED_COLLATERAL_ASSET || token == MINTER) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
        super._sweep(token, amount, receiver);
    }

    // ============ Safety Functions ============

    receive() external payable {
        // Allow contract to receive base asset for recovery
    }

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}
