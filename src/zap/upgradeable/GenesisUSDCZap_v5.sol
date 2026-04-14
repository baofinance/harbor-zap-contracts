// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "src/utils/upgradeable/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {IGenesisZapV5BaseErc20} from "src/interfaces/IGenesisZapV5BaseErc20.sol";
import {IGenesisZapV5Common} from "src/interfaces/IGenesisZapV5Common.sol";
import {GenesisZapBase_v1} from "src/zap/upgradeable/base/GenesisZapBase_v1.sol";
import {FxUSDZapNetworkConfig} from "src/zap/upgradeable/config/FxUSDZapNetworkConfig.sol";
import {FxUSDZapBase_v1} from "src/zap/upgradeable/asset/FxUSDZapBase_v1.sol";

/// @title GenesisUSDCZapV5 - Production Ready
/// @notice One-click zapper for depositing base asset or collateral into Genesis via wrapped collateral
/// @dev Enables users to deposit base asset or collateral in a single transaction
/// @dev Flow: base asset/collateral → wrapped collateral → Genesis deposit
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract GenesisUSDCZap_v5 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransient,
    BaoOwnable,
    GenesisZapBase_v1,
    FxUSDZapBase_v1,
    IGenesisZapV5Common,
    IGenesisZapV5BaseErc20
{
    using SafeERC20 for IERC20;

    // ========== Network Config (immutables) ==========
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

    // ========== Immutables ==========
    /// @notice Genesis contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable GENESIS;

    /// @dev Reserved slots for future storage variables. Shrink the array when appending new state (OZ upgradeable pattern).
    uint256[50] private __gap;

    // ========== Events ==========
    /// @dev `ZappedBaseAsset` / `ZappedCollateral` are declared on `GenesisZapBase_v1`.

    event Upgraded(address indexed implementation);

    // ========== Constructor ==========
    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept wrapped collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();

        if (genesis_ == address(0)) revert IZapErrors.ZeroAddress();

        FxUSDZapNetworkConfig.Config memory cfg = FxUSDZapNetworkConfig.load(block.chainid);
        if (cfg.fxsave == address(0)) revert IZapErrors.AssetNotSupportedOnChain(address(0), block.chainid);

        BASE_ASSET = cfg.usdc;
        COLLATERAL_ASSET = cfg.fxusd;
        WRAPPED_COLLATERAL_ASSET = cfg.fxsave;
        COLLATERAL_MANAGER = cfg.collateralManager;
        SWAP_ROUTER = cfg.swapRouter;
        CONVERT_SELECTOR = cfg.convertSelector;

        address expected = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (expected != WRAPPED_COLLATERAL_ASSET) {
            revert IZapErrors.WrappedCollateralMismatch(expected, WRAPPED_COLLATERAL_ASSET);
        }

        GENESIS = genesis_;
    }

    // ========== Initialization ==========
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

    // =============================================================
    // MAIN ZAP FUNCTIONS
    // =============================================================

    /// @notice Zap base asset → wrapped collateral → Genesis in one tx
    /// @dev Flow: base asset → wrapped collateral → Genesis deposit
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Who gets the Genesis shares
    /// @return sharesOut Amount of shares minted to Genesis
    function zapBaseAsset(uint256 baseAssetAmount, uint256 minWrappedCollateralOut, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        _requireSupportedAsset(BASE_ASSET);
        sharesOut = _zapBaseAssetToGenesisCore(baseAssetAmount, minWrappedCollateralOut, receiver);
    }

    /// @notice Zap collateral → wrapped collateral → Genesis in one tx
    /// @dev Flow: collateral → wrapped collateral → Genesis deposit
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Who gets the Genesis shares
    /// @return sharesOut Amount of shares minted to Genesis
    function zapCollateral(uint256 collateralAmount, uint256 minWrappedCollateralOut, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        sharesOut = _zapCollateralToGenesisCore(collateralAmount, minWrappedCollateralOut, receiver);
    }

    // =============================================================
    // PERMIT-BASED ZAP FUNCTIONS
    // =============================================================

    /// @notice Zap base asset → wrapped collateral → Genesis using permit (single transaction)
    /// @dev Flow: Permit base asset → base asset → wrapped collateral → Genesis deposit
    /// @param baseAssetAmount Amount of base asset to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive (slippage protection)
    /// @param receiver Who gets the Genesis shares
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return sharesOut Amount of shares minted to Genesis
    function zapBaseAssetWithPermit(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 sharesOut) {
        _requireSupportedAsset(BASE_ASSET);
        _permitBaseAsset(baseAssetAmount, deadline, v, r, s);

        sharesOut = _zapBaseAssetToGenesisCore(baseAssetAmount, minWrappedCollateralOut, receiver);
    }

    /// @notice Zap collateral → wrapped collateral → Genesis using permit (single transaction)
    /// @dev Flow: Permit collateral → collateral → wrapped collateral → Genesis deposit
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Who gets the Genesis shares
    /// @param deadline Permit signature deadline
    /// @param v Permit signature v component
    /// @param r Permit signature r component
    /// @param s Permit signature s component
    /// @return sharesOut Amount of shares minted to Genesis
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
        _permitCollateral(collateralAmount, deadline, v, r, s);

        sharesOut = _zapCollateralToGenesisCore(collateralAmount, minWrappedCollateralOut, receiver);
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    /// @dev Only tokens this zap is built for (immutables from `FxUSDZapNetworkConfig` + constructor checks).
    ///      Rejects `address(0)` and any token that is not base, collateral, or wrapped collateral.
    function _requireSupportedAsset(address asset) internal view {
        if (asset == BASE_ASSET) return;
        if (asset == COLLATERAL_ASSET) return;
        if (asset == WRAPPED_COLLATERAL_ASSET) return;
        revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
    }

    function _genesisAddress() internal view override returns (address) {
        return GENESIS;
    }

    function _wrappedCollateralAssetAddress() internal view override returns (address) {
        return WRAPPED_COLLATERAL_ASSET;
    }

    /// @dev Pull → convert → `_depositToGenesis` → `ZappedBaseAsset` (matches `GenesisETHZap_v5` `*Core` naming).
    function _zapBaseAssetToGenesisCore(
        uint256 baseAssetAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) internal returns (uint256 sharesOut) {
        sharesOut = _zapToGenesis(BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver);
        emit ZappedBaseAsset(_msgSender(), GENESIS, receiver, baseAssetAmount, sharesOut, sharesOut, 0, 0);
    }

    /// @dev `_zapToGenesis` pulls from sender, converts, deposits, then emits `ZappedCollateral`.
    function _zapCollateralToGenesisCore(
        uint256 collateralAmount,
        uint256 minWrappedCollateralOut,
        address receiver
    ) internal returns (uint256 sharesOut) {
        sharesOut = _zapToGenesis(COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver);
        emit ZappedCollateral(_msgSender(), GENESIS, receiver, collateralAmount, sharesOut, sharesOut, 0, 0);
    }

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
        IERC20Permit(COLLATERAL_ASSET).permit(_msgSender(), address(this), amount, deadline, v, r, s);
    }

    /// @notice Convert an input token to wrapped collateral via the diamond
    /// @param tokenIn Token to convert (base asset or collateral)
    /// @param amountIn Amount of tokenIn to convert
    /// @param minOut Minimum wrapped collateral expected (slippage protection)
    /// @return wrappedCollateralReceived Amount of wrapped collateral received
    function _convertToWrappedCollateral(address tokenIn, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 wrappedCollateralReceived)
    {
        wrappedCollateralReceived = _convertHeldTokenToWrappedCollateral(
            COLLATERAL_MANAGER,
            SWAP_ROUTER,
            WRAPPED_COLLATERAL_ASSET,
            CONVERT_SELECTOR,
            tokenIn,
            amountIn,
            minOut
        );
    }

    /// @notice Pull token, convert to wrapped collateral, and deposit into Genesis
    /// @dev Only `BASE_ASSET` and `COLLATERAL_ASSET` are valid here; `_requireSupportedAsset` also allows
    ///      `WRAPPED_COLLATERAL_ASSET` for previews and guards, but there is no wrapped-only zap path in this contract.
    /// @param tokenIn Token to zap (base asset or collateral)
    /// @param amountIn Amount of tokenIn to zap
    /// @param minWrappedCollateralOut Minimum wrapped collateral to receive
    /// @param receiver Address receiving Genesis shares
    /// @return wrappedCollateralReceived Amount of wrapped collateral deposited
    function _zapToGenesis(
        address tokenIn,
        uint256 amountIn,
        uint256 minWrappedCollateralOut,
        address receiver
    )
        internal
        returns (uint256 wrappedCollateralReceived)
    {
        if (amountIn == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();
        if (tokenIn != BASE_ASSET && tokenIn != COLLATERAL_ASSET) {
            revert IZapErrors.ZapTokenInNotSupported(tokenIn);
        }

        IERC20(tokenIn).safeTransferFrom(_msgSender(), address(this), amountIn);

        wrappedCollateralReceived = _convertToWrappedCollateral(
            tokenIn, amountIn, minWrappedCollateralOut
        );
        _depositToGenesis(wrappedCollateralReceived, receiver);

        // Clean approvals
        _safeApprove(IERC20(tokenIn), COLLATERAL_MANAGER, 0);
    }

    // =============================================================
    // VIEW FUNCTIONS (FRONTEND)
    // =============================================================

    /// @notice Real-time user balance in base asset terms
    /// @dev Not supported without a conversion oracle; kept for API parity
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfBaseAsset(address) external pure returns (uint256) {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Real-time user balance in collateral terms
    /// @dev Not supported without a conversion oracle; kept for API parity
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfCollateral(address) external pure returns (uint256) {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Total vault value in base asset terms
    /// @dev Not supported without a conversion oracle; kept for API parity
    // forge-lint: disable-next-line(mixed-case-function)
    function totalValueBaseAsset() external pure returns (uint256) {
        revert IZapErrors.PreviewNotSupported();
    }

    // =============================================================
    // PREVIEW FUNCTIONS
    // =============================================================

    /// @notice Preview fxSAVE (wrapped collateral) from USDC using ERC4626 `convertToShares` on fxSAVE.
    /// @dev Uses **$1 USDC ≈ 1 fxUSD** scaling (6→18 decimals); actual diamond output may differ—use slippage on zaps.
    function previewWrappedCollateralFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = _previewWrappedFromBaseInternal(baseAssetAmount);
    }

    /// @notice Preview fxSAVE from an fxUSD amount via `convertToShares`.
    function previewWrappedCollateralFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = _previewWrappedFromCollateralInternal(collateralAmount);
    }

    /// @notice Preview Genesis shares from USDC (same as wrapped preview; Genesis is 1:1 with fxSAVE).
    function previewSharesFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = _previewWrappedFromBaseInternal(baseAssetAmount);
        sharesOut = wrappedCollateralAmount;
    }

    /// @notice Preview Genesis shares from fxUSD (1:1 with fxSAVE shares from `convertToShares`).
    function previewSharesFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = _previewWrappedFromCollateralInternal(collateralAmount);
        sharesOut = wrappedCollateralAmount;
    }

    function _previewWrappedFromBaseInternal(uint256 baseAssetAmount) internal view returns (uint256 wrappedCollateralAmount) {
        _requireSupportedAsset(BASE_ASSET);
        wrappedCollateralAmount = _previewFxSaveSharesFromUsdcAssumedPeg(
            WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, baseAssetAmount
        );
    }

    function _previewWrappedFromCollateralInternal(uint256 collateralAmount)
        internal
        view
        returns (uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount =
            _previewFxSaveSharesFromFxUsd(WRAPPED_COLLATERAL_ASSET, COLLATERAL_ASSET, collateralAmount);
    }

    /// @inheritdoc IGenesisZapV5Common
    function previewSharesFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        pure
        returns (uint256 sharesOut)
    {
        sharesOut = _previewGenesisSharesFromWrappedCollateral(wrappedCollateralAmount);
    }

    /// @inheritdoc IGenesisZapV5Common
    function zapName() external view returns (string memory) {
        return _genesisZapDisplayName();
    }

    // =============================================================
    // OWNER FUNCTIONS
    // =============================================================

    /// @notice Rescue stuck native ETH (uses `call` so a contract owner with receive/fallback can recover)
    function rescueNativeAsset() external onlyOwner {
        address to = owner();
        uint256 amount = address(this).balance;
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert IZapErrors.NativeTransferFailed();
    }

    /// @notice Rescue any ERC20 (except base/collateral/wrapped collateral/Genesis)
    function rescueToken(address token) external onlyOwner {
        if (
            token == BASE_ASSET || token == COLLATERAL_ASSET || token == WRAPPED_COLLATERAL_ASSET
                || token == GENESIS
        ) {
            revert IZapErrors.CannotRescueProtectedToken(token);
        }
        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)));
    }

    // =============================================================
    // RECEIVE / FALLBACK
    // =============================================================

    receive() external payable {}

    fallback() external payable {
        revert IZapErrors.FunctionNotFound();
    }
}

