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
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {ISTETHV2, IStETH} from "src/interfaces/IStETH.sol";
import {IWstETHWrapV2, IWstETH} from "src/interfaces/IWstETH.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {IGenesisZapV5BaseNative} from "src/interfaces/IGenesisZapV5BaseNative.sol";
import {IGenesisZapV5Common} from "src/interfaces/IGenesisZapV5Common.sol";
import {WstETHConstants} from "src/constants/ethereum/WstETHConstants.sol";

/// @title GenesisETHZap V5
/// @notice One-click zapper: base asset or collateral → wrapped collateral → Genesis vault
/// @dev Uses correct share-based conversion (critical for 2025+ collateral ratio)
/// @dev Includes slippage protection, accurate previews, and real-time value tracking
/// @dev Uses UUPS proxy, upgradeable
/// @author Harbor Yield Protocol
/// @custom:oz-upgrades
// solhint-disable-next-line contract-name-camelcase
contract GenesisETHZap_v5 is
    Initializable,
    UUPSUpgradeable,
    ContextUpgradeable,
    ReentrancyGuardTransient,
    BaoOwnable,
    IGenesisZapV5Common,
    IGenesisZapV5BaseNative
{
    using SafeERC20 for IERC20;

    // ========== Constants ==========
    address public constant DEFAULT_REFERRAL = WstETHConstants.DEFAULT_REFERRAL;
    address public constant BASE_ASSET = address(0);
    address public constant COLLATERAL_ASSET = WstETHConstants.STETH;
    address public constant WRAPPED_COLLATERAL_ASSET = WstETHConstants.WSTETH;

    // ========== Immutables ==========
    address public immutable GENESIS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IStETH public immutable collateralToken;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IWstETH public immutable wrappedCollateralToken;

    // ========== Configurable ==========
    address public referral;

    /// @dev Reserved slots for future storage variables. Shrink the array when appending new state (OZ upgradeable pattern).
    uint256[50] private __gap;

    // ========== Events ==========
    /// @notice Emitted when base asset is successfully zapped into Genesis (same shape as `GenesisUSDCZap_v5` for indexers)
    /// @param wrappedCollateralOut wstETH deposited (1:1 Genesis shares for this vault)
    /// @param sharesOut Genesis shares minted to receiver
    /// @param baseAssetValueNow ETH-equivalent value of position (0 on USDC zap)
    /// @param collateralValueNow stETH-equivalent (0 on USDC zap)
    event ZappedBaseAsset(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 baseAssetIn,
        uint256 wrappedCollateralOut,
        uint256 sharesOut,
        uint256 baseAssetValueNow,
        uint256 collateralValueNow
    );

    /// @notice Emitted when collateral is successfully zapped into Genesis (same shape as `GenesisUSDCZap_v5`)
    event ZappedCollateral(
        address indexed user,
        address indexed genesis,
        address indexed receiver,
        uint256 collateralIn,
        uint256 wrappedCollateralOut,
        uint256 sharesOut,
        uint256 baseAssetValueNow,
        uint256 collateralValueNow
    );

    event ReferralUpdated(address indexed oldReferral, address indexed newReferral);
    event Upgraded(address indexed implementation);

    // ========== Constructor ==========
    /// @notice Deploy zapper locked to a specific Genesis vault
    /// @param genesis_ Genesis vault address (must accept wrapped collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();
        if (genesis_ == address(0)) revert IZapErrors.ZeroAddress();

        // Verify that wrapped collateral matches the Genesis wrapped collateral token
        address expectedCollateral = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (WRAPPED_COLLATERAL_ASSET != expectedCollateral) {
            revert IZapErrors.WrappedCollateralMismatch(expectedCollateral, WRAPPED_COLLATERAL_ASSET);
        }

        GENESIS = genesis_;
        collateralToken = IStETH(COLLATERAL_ASSET);
        wrappedCollateralToken = IWstETH(WRAPPED_COLLATERAL_ASSET);
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

        address initialReferral = referral_ == address(0) ? DEFAULT_REFERRAL : referral_;
        referral = initialReferral;
        emit ReferralUpdated(address(0), initialReferral);
    }

    /// @notice The check that allows this contract to be upgraded
    /// @dev In UUPS proxies the implementation is responsible for upgrading itself
    /// @dev Only owners can upgrade this contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        emit Upgraded(newImplementation);
    } // solhint-disable-line no-empty-blocks

    // =================================================================
    // ====================== USER FACING ZAPS =========================
    // =================================================================

    /// @notice Zap base asset → collateral → wrapped collateral → Genesis in one transaction
    /// @dev Includes slippage protection against front-running/MEV
    /// @param receiver Address receiving Genesis vault shares
    /// @param minWrappedCollateralOut Minimum acceptable wrapped collateral (use preview for 0.1-0.5% buffer)
    /// @param minBaseAssetEquivalentOut Minimum acceptable base asset value (slippage protection)
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapBaseAsset(
        address receiver,
        uint256 minWrappedCollateralOut,
        uint256 minBaseAssetEquivalentOut
    )
        external
        payable
        nonReentrant
        returns (uint256 sharesOut)
    {
        _requireSupportedAsset(BASE_ASSET);
        if (msg.value == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 baseAssetIn = msg.value;

        // 1. Base asset → collateral via Lido
        uint256 collateralReceived = _convertBaseAssetToCollateral(baseAssetIn);
        // 2. collateral → wrapped collateral
        sharesOut = _convertCollateralToWrappedCollateral(collateralReceived);
        // 3. Slippage protection
        if (sharesOut < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(sharesOut, minWrappedCollateralOut);
        }
        // 4. Value protection
        (uint256 baseAssetValueNow,) = _getCurrentValuesBaseCollateral(sharesOut);
        if (baseAssetValueNow < minBaseAssetEquivalentOut) {
            revert IZapErrors.SlippageTooHighBaseAssetValue(baseAssetValueNow, minBaseAssetEquivalentOut);
        }
        // 5. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 6. Emit real-time values for indexers/frontends
        (uint256 baseAssetNow, uint256 collateralNow) = _getCurrentValuesBaseCollateral(sharesOut);
        emit ZappedBaseAsset(
            _msgSender(), GENESIS, receiver, baseAssetIn, sharesOut, sharesOut, baseAssetNow, collateralNow
        );
    }

    /// @notice Zap existing collateral → wrapped collateral → Genesis
    /// @param collateralAmount Amount of collateral to zap
    /// @param minWrappedCollateralOut Minimum acceptable wrapped collateral out
    /// @param receiver Address receiving Genesis vault shares
    /// @return sharesOut Exact amount of Genesis shares minted
    function zapCollateral(uint256 collateralAmount, uint256 minWrappedCollateralOut, address receiver)
        external
        nonReentrant
        returns (uint256 sharesOut)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        if (collateralAmount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        // 1. Transfer collateral from user
        IERC20(COLLATERAL_ASSET).safeTransferFrom(_msgSender(), address(this), collateralAmount);
        // 2. collateral → wrapped collateral
        sharesOut = _convertCollateralToWrappedCollateral(collateralAmount);
        // 3. Slippage protection
        if (sharesOut < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(sharesOut, minWrappedCollateralOut);
        }
        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 5. Emit real-time values for indexers/frontends
        (uint256 baseAssetNow, uint256 collateralNow) = _getCurrentValuesBaseCollateral(sharesOut);
        emit ZappedCollateral(
            _msgSender(), GENESIS, receiver, collateralAmount, sharesOut, sharesOut, baseAssetNow, collateralNow
        );
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

        _permitCollateral(collateralAmount, deadline, v, r, s);

        // 1. Transfer collateral from user
        IERC20(COLLATERAL_ASSET).safeTransferFrom(_msgSender(), address(this), collateralAmount);
        // 2. collateral → wrapped collateral
        sharesOut = _convertCollateralToWrappedCollateral(collateralAmount);
        // 3. Slippage protection
        if (sharesOut < minWrappedCollateralOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(sharesOut, minWrappedCollateralOut);
        }
        // 4. Deposit to Genesis
        _depositToGenesis(sharesOut, receiver);
        // 5. Emit real-time values for indexers/frontends
        (uint256 baseAssetNow, uint256 collateralNow) = _getCurrentValuesBaseCollateral(sharesOut);
        emit ZappedCollateral(
            _msgSender(), GENESIS, receiver, collateralAmount, sharesOut, sharesOut, baseAssetNow, collateralNow
        );
    }

    function _requireSupportedAsset(address asset) internal view {
        if (block.chainid != 1 && asset == address(0)) {
            revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
        }
    }

    // =================================================================
    // ====================== INTERNAL HELPERS =========================
    // =================================================================

    /// @notice Convert base asset to collateral via Lido
    /// @param baseAssetAmount Amount of base asset to convert
    /// @return collateralReceived Amount of collateral received (using balance checks, never trust return value)
    function _convertBaseAssetToCollateral(uint256 baseAssetAmount) internal returns (uint256 collateralReceived) {
        uint256 collateralBefore = IERC20(COLLATERAL_ASSET).balanceOf(address(this));
        ISTETHV2(COLLATERAL_ASSET).submit{value: baseAssetAmount}(referral);
        collateralReceived = IERC20(COLLATERAL_ASSET).balanceOf(address(this)) - collateralBefore;
        if (collateralReceived == 0) revert IZapErrors.NoCollateralReceived();
    }

    /// @notice Convert collateral to wrapped collateral
    /// @param collateralAmount Amount of collateral to convert
    /// @return wrappedCollateralReceived Amount of wrapped collateral received (using balance checks, never trust return value)
    function _convertCollateralToWrappedCollateral(uint256 collateralAmount)
        internal
        returns (uint256 wrappedCollateralReceived)
    {
        IERC20(COLLATERAL_ASSET).forceApprove(WRAPPED_COLLATERAL_ASSET, collateralAmount);
        uint256 wrappedCollateralBefore = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        IWstETHWrapV2(WRAPPED_COLLATERAL_ASSET).wrap(collateralAmount);
        wrappedCollateralReceived = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this))
            - wrappedCollateralBefore;
        if (wrappedCollateralReceived == 0) revert IZapErrors.NoWrappedCollateralReceived();
        IERC20(COLLATERAL_ASSET).forceApprove(WRAPPED_COLLATERAL_ASSET, 0);
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

    /// @notice Deposit wrapped collateral into Genesis and validate shares
    /// @dev Confirms mint via receiver share balance delta; reverts `MintMismatchExpected` if mismatch.
    /// @param amount Amount of wrapped collateral to deposit
    /// @param receiver Address receiving Genesis shares
    function _depositToGenesis(uint256 amount, address receiver) internal {
        if (amount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 balance = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        if (balance < amount) revert IZapErrors.InsufficientBalance(balance, amount);

        uint256 sharesBefore = IGenesis(GENESIS).balanceOf(receiver);

        uint256 currentAllowance = IERC20(WRAPPED_COLLATERAL_ASSET).allowance(address(this), GENESIS);
        if (currentAllowance < amount) {
            if (currentAllowance > 0) {
                IERC20(WRAPPED_COLLATERAL_ASSET).approve(GENESIS, 0);
            }
            IERC20(WRAPPED_COLLATERAL_ASSET).approve(GENESIS, type(uint256).max);
        }

        IGenesis(GENESIS).deposit(amount, receiver);

        uint256 sharesAfter = IGenesis(GENESIS).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != amount) {
            revert IZapErrors.MintMismatchExpected(amount, sharesReceived);
        }
    }

    /// @notice Returns real-time redeemable values for any wrapped collateral amount
    /// @param wrappedCollateralAmount Amount of wrapped collateral
    /// @return baseAssetValue Equivalent base asset value
    /// @return collateralValue Equivalent collateral value
    function _getCurrentValuesBaseCollateral(uint256 wrappedCollateralAmount)
        internal
        view
        returns (uint256 baseAssetValue, uint256 collateralValue)
    {
        collateralValue = wrappedCollateralToken.getStETHByWstETH(wrappedCollateralAmount);
        baseAssetValue = collateralToken.getPooledEthByShares(collateralValue);
    }

    // =================================================================
    // ====================== VIEW FUNCTIONS (FRONTEND) ===============
    // =================================================================

    /// @notice Real-time user balance in growing base asset terms (primary display value)
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfBaseAsset(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        if (shares == 0) return 0;
        (uint256 baseAssetValue,) = _getCurrentValuesBaseCollateral(shares);
        return baseAssetValue;
    }

    /// @notice Real-time user balance in collateral terms
    // forge-lint: disable-next-line(mixed-case-function)
    function balanceOfCollateral(address user) external view returns (uint256) {
        uint256 shares = IERC20(GENESIS).balanceOf(user);
        return shares == 0 ? 0 : wrappedCollateralToken.getStETHByWstETH(shares);
    }

    /// @notice Total vault value in real base asset (grows daily)
    // forge-lint: disable-next-line(mixed-case-function)
    function totalValueBaseAsset() external view returns (uint256) {
        uint256 totalWrappedCollateral = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(GENESIS);
        if (totalWrappedCollateral == 0) return 0;
        (uint256 baseAssetValue,) = _getCurrentValuesBaseCollateral(totalWrappedCollateral);
        return baseAssetValue;
    }

    // =================================================================
    // ====================== PREVIEW FUNCTIONS =======================
    // =================================================================

    /// @notice Preview the expected wrapped collateral output from a base asset amount
    /// @param baseAssetAmount Amount of base asset
    /// @return wrappedCollateralAmount Expected wrapped collateral amount (which equals Genesis shares)
    function previewWrappedCollateralFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(BASE_ASSET);
        uint256 collateralShares = IStETH(COLLATERAL_ASSET).getSharesByPooledEth(baseAssetAmount);
        uint256 collateralAmount = IStETH(COLLATERAL_ASSET).getPooledEthByShares(collateralShares);
        wrappedCollateralAmount = IWstETH(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
    }

    /// @notice Preview the expected wrapped collateral output from a collateral amount
    /// @param collateralAmount Amount of collateral
    /// @return wrappedCollateralAmount Expected wrapped collateral amount (which equals Genesis shares)
    function previewWrappedCollateralFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 wrappedCollateralAmount)
    {
        _requireSupportedAsset(COLLATERAL_ASSET);
        wrappedCollateralAmount = IWstETH(WRAPPED_COLLATERAL_ASSET).getWstETHByStETH(collateralAmount);
    }

    /// @notice Preview the expected Genesis shares from a base asset amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    /// @param baseAssetAmount Amount of base asset
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewSharesFromBase(uint256 baseAssetAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = this.previewWrappedCollateralFromBase(baseAssetAmount);
        sharesOut = wrappedCollateralAmount; // 1:1 mapping
    }

    /// @notice Preview the expected Genesis shares from a collateral amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    /// @param collateralAmount Amount of collateral
    /// @return sharesOut Expected Genesis shares that will be minted
    /// @return wrappedCollateralAmount Expected wrapped collateral amount
    function previewSharesFromCollateral(uint256 collateralAmount)
        external
        view
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        wrappedCollateralAmount = this.previewWrappedCollateralFromCollateral(collateralAmount);
        sharesOut = wrappedCollateralAmount; // 1:1 mapping
    }

    /// @notice Preview the expected Genesis shares from a wrapped collateral amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    function previewSharesFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        pure
        returns (uint256 sharesOut)
    {
        sharesOut = wrappedCollateralAmount;
    }

    /// @notice Human-readable zap name based on the pegged token
    function zapName() external view returns (string memory) {
        address peggedToken = IGenesis(GENESIS).PEGGED_TOKEN();
        return string(abi.encodePacked("Genesis zap ", IERC20Metadata(peggedToken).name()));
    }

    // =================================================================
    // ====================== OWNER FUNCTIONS ==========================
    // =================================================================

    /// @notice Update Lido referral address
    function setReferral(address newReferral) external onlyOwner {
        emit ReferralUpdated(referral, newReferral);
        referral = newReferral;
    }

    /// @notice Rescue stuck base asset
    function rescueNativeAsset() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /// @notice Rescue any ERC20 (except collateral/wrapped collateral/Genesis which should never be stuck)
    function rescueToken(address token) external onlyOwner {
        if (token == COLLATERAL_ASSET || token == WRAPPED_COLLATERAL_ASSET || token == GENESIS) {
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
