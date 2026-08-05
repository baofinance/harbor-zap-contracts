// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {HarborOwnable} from "@bao/HarborOwnable.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IStETH} from "@harborzap/interfaces/IStETH.sol";
import {IWstETH} from "@harborzap/interfaces/IWstETH.sol";
import {IZapErrors} from "@harborzap/interfaces/IZapErrors.sol";
import {IGenesisZapV1Native} from "@harborzap/interfaces/IGenesisZapV1Native.sol";
import {IGenesisZapV1Common} from "@harborzap/interfaces/IGenesisZapV1Common.sol";
import {StETHZapNetworkConfig} from "@harborzap/zap/upgradeable/config/StETHZapNetworkConfig.sol";
import {GenesisZapBase_v1} from "@harborzap/zap/upgradeable/base/GenesisZapBase_v1.sol";
import {ZapIntake} from "@harborzap/zap/upgradeable/base/ZapIntake.sol";
import {StETHZapBase_v1} from "@harborzap/zap/upgradeable/asset/StETHZapBase_v1.sol";

/// @title GenesisETHZap V1
/// @notice One-click zapper: base asset or collateral → wrapped collateral → Genesis vault
/// @dev Uses correct share-based conversion (critical for 2025+ collateral ratio)
/// @dev Includes slippage protection, accurate previews, and real-time value tracking
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-capwords
contract GenesisETHZap_v1 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    HarborOwnable,
    TokenHolder_v2,
    GenesisZapBase_v1,
    StETHZapBase_v1,
    IGenesisZapV1Common,
    IGenesisZapV1Native
{
    using SafeERC20 for IERC20;

    // ========== Network Config (immutables) ==========
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

    // ========== Immutables ==========
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable GENESIS;

    // ========== Events ==========
    /// @dev `ZappedBaseAsset` / `ZappedCollateral` are declared on `GenesisZapBase_v1`.

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wrapped collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();
        if (genesis_ == address(0)) revert IZapErrors.ZeroAddress();
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

        // Verify that wrapped collateral matches the Genesis wrapped collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (WRAPPED_COLLATERAL_ASSET != expectedCollateral) {
            revert IZapErrors.WrappedCollateralMismatch(expectedCollateral, WRAPPED_COLLATERAL_ASSET);
        }

        GENESIS = genesis_;
    }

    // ========== Initialization ==========
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

    // =================================================================
    // ====================== USER FACING ZAPS =========================
    // =================================================================

    /// @notice Zap native base asset (ETH) → collateral → wrapped collateral → Genesis in one transaction
    /// @dev Emits `ZappedBaseAsset` (see `GenesisZapBase_v1`) for indexer parity with `GenesisUSDCZap_v1`; there is no `zapBaseAsset` on this contract.
    ///      Note on the min-out checks: this path has no market execution (Lido `submit` credits stETH 1:1,
    ///      wrap is rate-based), so there is nothing to sandwich. Both bounds only guard against stETH
    ///      share-rate drift between preview and execution (typically a daily rebase, well under 0.1%) and
    ///      act as sanity checks on the Lido/wstETH contracts; they derive from the same wrapped amount, so
    ///      setting either one is sufficient.
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWrappedCollateralOut Minimum acceptable wrapped collateral out (from preview; 0 skips)
    /// @param minBaseAssetEquivalentOut Minimum ETH-equivalent value of the wrapped collateral (0 skips)
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapNativeAsset(
        address receiver,
        uint256 minWrappedCollateralOut,
        uint256 minBaseAssetEquivalentOut
    ) external payable nonReentrant returns (uint256 sharesOut) {
        _requireSupportedAsset(BASE_ASSET);
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 baseAssetIn = msg.value;

        // 1. Base asset → collateral via Lido
        uint256 collateralReceived = _convertBaseAssetToCollateral(COLLATERAL_ASSET, DEFAULT_REFERRAL, baseAssetIn);
        // 2. collateral → wrapped collateral
        sharesOut = _wrapCollateralToWrappedCollateral(COLLATERAL_ASSET, WRAPPED_COLLATERAL_ASSET, collateralReceived);
        // 3. Slippage protection
        if (sharesOut < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(sharesOut, minWrappedCollateralOut);
        }
        // 4. Value protection + indexer fields (single oracle read; values depend only on wrapped amount)
        (uint256 baseAssetNow, uint256 collateralNow) = _getCurrentValuesBaseCollateral(sharesOut);
        if (baseAssetNow < minBaseAssetEquivalentOut) {
            revert IZapErrors.SlippageTooHighBaseAssetValue(baseAssetNow, minBaseAssetEquivalentOut);
        }
        // 5. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        emit ZappedBaseAsset(
            _msgSender(),
            GENESIS,
            receiver,
            baseAssetIn,
            sharesOut,
            sharesOut,
            baseAssetNow,
            collateralNow
        );
    }

    /// @notice Zap existing collateral → wrapped collateral → Genesis
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum acceptable wrapped collateral out
    /// @param receiver Address receiving Genesis vault shares
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapCollateral(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) external nonReentrant returns (uint256 sharesOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 baseline = IERC20(COLLATERAL_ASSET).balanceOf(address(this));
        uint256 received = ZapIntake.pullMeasured(IERC20(COLLATERAL_ASSET), _msgSender(), collateralAmount);
        sharesOut = _zapCollateralToGenesisCore(received, minWrappedCollateralOut, receiver);
        ZapIntake.refundLeftoverAbove(IERC20(COLLATERAL_ASSET), baseline, _msgSender());
    }

    /// @notice Zap collateral → wrapped collateral → Genesis using permit (single transaction, no approval needed)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Genesis deposit
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Address that will receive the Genesis shares
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return sharesOut Amount of Genesis shares minted
    function zapCollateralWithPermit(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 sharesOut) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        _permitCollateral(COLLATERAL_ASSET, _msgSender(), collateralAmount, deadline, v, r, s);

        uint256 baseline = IERC20(COLLATERAL_ASSET).balanceOf(address(this));
        uint256 received = ZapIntake.pullMeasured(IERC20(COLLATERAL_ASSET), _msgSender(), collateralAmount);
        sharesOut = _zapCollateralToGenesisCore(received, minWrappedCollateralOut, receiver);
        ZapIntake.refundLeftoverAbove(IERC20(COLLATERAL_ASSET), baseline, _msgSender());
    }

    function _requireSupportedAsset(address asset) internal view {
        if (asset == BASE_ASSET && SUPPORTS_BASE_ASSET) return;
        if (asset == COLLATERAL_ASSET && SUPPORTS_COLLATERAL_ASSET) return;
        revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
    }

    function _genesisAddress() internal view override returns (address) {
        return GENESIS;
    }

    function _wrappedCollateralAssetAddress() internal view override returns (address) {
        return WRAPPED_COLLATERAL_ASSET;
    }

    function _genesisShareBalance(address user) internal view returns (uint256) {
        return IERC20(GENESIS).balanceOf(user);
    }

    /// @dev Shared by collateral previews; uses `COLLATERAL_ASSET` / `WRAPPED_COLLATERAL_ASSET` immutables.
    function _previewWrappedFromCollateralInternal(
        uint256 collateralAmount
    ) internal view returns (uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETH(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
    }

    // =================================================================
    // ====================== INTERNAL HELPERS =========================
    // =================================================================

    /// @dev Collateral already transferred to this contract.
    function _zapCollateralToGenesisCore(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) internal returns (uint256 sharesOut) {
        sharesOut = _wrapCollateralToWrappedCollateral(COLLATERAL_ASSET, WRAPPED_COLLATERAL_ASSET, collateralAmount);
        if (sharesOut < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(sharesOut, minWrappedCollateralOut);
        }
        _depositToGenesis(sharesOut, receiver);
        (uint256 baseAssetNow, uint256 collateralNow) = _getCurrentValuesBaseCollateral(sharesOut);
        emit ZappedCollateral(
            _msgSender(),
            GENESIS,
            receiver,
            collateralAmount,
            sharesOut,
            sharesOut,
            baseAssetNow,
            collateralNow
        );
    }

    /// @notice Returns real-time redeemable values for any wrapped collateral amount
    /// @param wrappedCollateralAmount Amount of wrapped collateral
    /// @return baseAssetValue Equivalent base asset value
    /// @return collateralValue Equivalent collateral value
    function _getCurrentValuesBaseCollateral(
        uint256 wrappedCollateralAmount
    ) internal view returns (uint256 baseAssetValue, uint256 collateralValue) {
        collateralValue = IWstETH(WRAPPED_COLLATERAL_ASSET).getStETHByWstETH(wrappedCollateralAmount);
        baseAssetValue = IStETH(COLLATERAL_ASSET).getPooledEthByShares(collateralValue);
    }

    // =================================================================
    // ====================== VIEW FUNCTIONS (FRONTEND) ===============
    // =================================================================

    /// @notice Real-time user balance in growing base asset terms (primary display value)
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfBaseAsset(address user) external view returns (uint256) {
        uint256 shares = _genesisShareBalance(user);
        // slither-disable-next-line incorrect-equality — early-out for empty share balance
        if (shares == 0) return 0;
        (uint256 baseAssetValue, ) = _getCurrentValuesBaseCollateral(shares);
        return baseAssetValue;
    }

    /// @notice Real-time user balance in collateral terms
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfCollateral(address user) external view returns (uint256) {
        uint256 shares = _genesisShareBalance(user);
        // slither-disable-next-line incorrect-equality — early-out for empty share balance
        return shares == 0 ? 0 : IWstETH(WRAPPED_COLLATERAL_ASSET).getStETHByWstETH(shares);
    }

    /// @notice Total vault value in real base asset (grows daily)
    // forge-lint: disable-next-line(mixed-case-function)
    function totalValueBaseAsset() external view returns (uint256) {
        uint256 totalWrappedCollateral = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(GENESIS);
        // slither-disable-next-line incorrect-equality — early-out for empty vault
        if (totalWrappedCollateral == 0) return 0;
        (uint256 baseAssetValue, ) = _getCurrentValuesBaseCollateral(totalWrappedCollateral);
        return baseAssetValue;
    }

    // =================================================================
    // ====================== PREVIEW FUNCTIONS =======================
    // =================================================================

    /// @notice Preview the expected wrapped collateral output from a base asset amount
    /// @param baseAssetAmount Amount of base asset
    /// @return wrappedCollateralAmount Expected wrapped collateral amount (which equals Genesis shares)
    function previewWrappedCollateralFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _estimateWrappedCollateralFromBase(
            COLLATERAL_ASSET,
            WRAPPED_COLLATERAL_ASSET,
            baseAssetAmount
        );
    }

    /// @notice Preview the expected wrapped collateral output from a collateral amount
    /// @param collateralAmount Amount of collateral
    /// @return wrappedCollateralAmount Expected wrapped collateral amount (which equals Genesis shares)
    function previewWrappedCollateralFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 wrappedCollateralAmount) {
        wrappedCollateralAmount = _previewWrappedFromCollateralInternal(collateralAmount);
    }

    /// @notice Preview the expected Genesis shares from a base asset amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    /// @param baseAssetAmount Amount of base asset
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewSharesFromBase(
        uint256 baseAssetAmount
    ) external view returns (uint256 sharesOut, uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _estimateWrappedCollateralFromBase(
            COLLATERAL_ASSET,
            WRAPPED_COLLATERAL_ASSET,
            baseAssetAmount
        );
        sharesOut = wrappedCollateralAmount;
    }

    /// @notice Preview the expected Genesis shares from a collateral amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    /// @param collateralAmount Amount of collateral
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewSharesFromCollateral(
        uint256 collateralAmount
    ) external view returns (uint256 sharesOut, uint256 wrappedCollateralAmount) {
        wrappedCollateralAmount = _previewWrappedFromCollateralInternal(collateralAmount);
        sharesOut = wrappedCollateralAmount;
    }

    /// @inheritdoc IGenesisZapV1Common
    function previewSharesFromWrappedCollateral(
        uint256 wrappedCollateralAmount
    ) external pure returns (uint256 sharesOut) {
        sharesOut = _previewGenesisSharesFromWrappedCollateral(wrappedCollateralAmount);
    }

    /// @inheritdoc IGenesisZapV1Common
    function zapName() external view returns (string memory) {
        return _genesisZapDisplayName();
    }

    // =================================================================
    // ====================== OWNER FUNCTIONS ==========================
    // =================================================================

    /// @inheritdoc IGenesisZapV1Native
    function referral() external view returns (address) {
        return DEFAULT_REFERRAL;
    }

    /// @notice Rescue stuck native ETH (uses `call` so a contract owner with receive/fallback can recover)
    function rescueNativeAsset() external onlyOwner {
        address to = owner();
        uint256 amount = address(this).balance;
        // slither-disable-next-line low-level-calls — intentional: `.transfer` can brick contract owners
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert IZapErrors.NativeTransferFailed();
    }

    /// @notice Rescue any ERC20 (except collateral/wrapped collateral/Genesis). Prefer `sweep`.
    function rescueToken(address token) external onlyOwner {
        _sweep(token, IERC20(token).balanceOf(address(this)), owner());
    }

    function _sweep(address token, uint256 amount, address receiver) internal override {
        if (token == COLLATERAL_ASSET || token == WRAPPED_COLLATERAL_ASSET || token == GENESIS) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
        super._sweep(token, amount, receiver);
    }

    // =================================================================
    // ====================== RECEIVE / FALLBACK =======================
    // =================================================================

    receive() external payable {}

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}
