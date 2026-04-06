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
import {IFxUSDDiamondV2} from "src/interfaces/IFxUSD.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";
import {IGenesisZapV5BaseErc20} from "src/interfaces/IGenesisZapV5BaseErc20.sol";
import {IGenesisZapV5Common} from "src/interfaces/IGenesisZapV5Common.sol";
import {FxSAVEConstants} from "src/constants/ethereum/FxSAVEConstants.sol";

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
    IGenesisZapV5Common,
    IGenesisZapV5BaseErc20
{
    using SafeERC20 for IERC20;

    // ============ Constants ============
    /// @notice Base asset address (mainnet)
    address public constant USDC = FxSAVEConstants.USDC;
    /// @notice Collateral token address (mainnet)
    address public constant FXUSD = FxSAVEConstants.FXUSD;
    /// @notice Wrapped collateral vault address (mainnet)
    address public constant FXSAVE = FxSAVEConstants.FXSAVE;
    /// @notice fxUSD Diamond contract address (handles deposits to wrapped collateral)
    address public constant FXUSD_DIAMOND = FxSAVEConstants.FXUSD_DIAMOND;
    /// @notice fxUSD swap router/converter address (for base asset and collateral deposits)
    address public constant FXUSD_SWAP_ROUTER = FxSAVEConstants.FXUSD_SWAP_ROUTER;
    address public constant BASE_ASSET = USDC;
    address public constant COLLATERAL_ASSET = FXUSD;
    address public constant WRAPPED_COLLATERAL_ASSET = FXSAVE;

    // Selector for IFxProtocolRouter.convert(address,uint256,uint256,bytes)
    bytes4 private constant CONVERT_SELECTOR = FxSAVEConstants.CONVERT_SELECTOR;

    // ============ Immutables ============
    /// @notice Genesis contract address
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable GENESIS;

    /// @dev Reserved slots for future storage variables. Shrink the array when appending new state (OZ upgradeable pattern).
    uint256[50] private __gap;

    // ============ Events ============
    /// @notice Emitted when base asset is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param baseAssetIn Amount of base asset deposited
    /// @param wrappedCollateralOut Amount of wrapped collateral received
    /// @param sharesOut Amount of shares minted to Genesis
    /// @param baseAssetValueNow USDC zap: always 0 (no oracle); ETH zap: valuation field
    /// @param collateralValueNow USDC zap: always 0 (no oracle); ETH zap: valuation field
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

    /// @notice Emitted when collateral is zapped into Genesis
    /// @param user Address that initiated the zap
    /// @param genesis Address of the Genesis contract
    /// @param receiver Address that will receive the Genesis shares
    /// @param collateralIn Amount of collateral deposited
    /// @param wrappedCollateralOut Amount of wrapped collateral received
    /// @param sharesOut Amount of shares minted to Genesis
    /// @param baseAssetValueNow USDC zap: always 0
    /// @param collateralValueNow USDC zap: always 0
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
    event Upgraded(address indexed implementation);

    // ============ Constructor ============
    /// @notice Constructor sets the Genesis address
    /// @param genesis_ Address of the Genesis contract (must accept wrapped collateral)
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address genesis_) {
        _disableInitializers();

        if (genesis_ == address(0)) revert IZapErrors.ZeroAddress();

        address expected = IGenesis(genesis_).WRAPPED_COLLATERAL_TOKEN();
        if (expected != WRAPPED_COLLATERAL_ASSET) {
            revert IZapErrors.WrappedCollateralMismatch(expected, WRAPPED_COLLATERAL_ASSET);
        }

        GENESIS = genesis_;
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
        uint256 wrappedCollateralReceived =
            _zapToGenesis(BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver);
        sharesOut = wrappedCollateralReceived;
        emit ZappedBaseAsset(
            _msgSender(), GENESIS, receiver, baseAssetAmount, wrappedCollateralReceived, sharesOut, 0, 0
        );
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
        uint256 wrappedCollateralReceived =
            _zapToGenesis(COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver);
        sharesOut = wrappedCollateralReceived;
        emit ZappedCollateral(
            _msgSender(), GENESIS, receiver, collateralAmount, wrappedCollateralReceived, sharesOut, 0, 0
        );
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

        uint256 wrappedCollateralReceived =
            _zapToGenesis(BASE_ASSET, baseAssetAmount, minWrappedCollateralOut, receiver);
        sharesOut = wrappedCollateralReceived;
        emit ZappedBaseAsset(
            _msgSender(), GENESIS, receiver, baseAssetAmount, wrappedCollateralReceived, sharesOut, 0, 0
        );
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

        uint256 wrappedCollateralReceived =
            _zapToGenesis(COLLATERAL_ASSET, collateralAmount, minWrappedCollateralOut, receiver);
        sharesOut = wrappedCollateralReceived;
        emit ZappedCollateral(
            _msgSender(), GENESIS, receiver, collateralAmount, wrappedCollateralReceived, sharesOut, 0, 0
        );
    }

    // =============================================================
    // INTERNAL HELPERS
    // =============================================================

    function _requireSupportedAsset(address asset) internal view {
        if (block.chainid != 1 && asset == address(0)) {
            revert IZapErrors.AssetNotSupportedOnChain(asset, block.chainid);
        }
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
        IERC20 token = IERC20(tokenIn);

        // Approve diamond if needed
        _safeApprove(token, FXUSD_DIAMOND, amountIn);

        // Encode converter call: convert(tokenIn, amountIn, minOut, "")
        bytes memory data = abi.encodeWithSelector(CONVERT_SELECTOR, tokenIn, amountIn, minOut, bytes(""));

        IFxUSDDiamondV2.ConvertInParams memory params = IFxUSDDiamondV2.ConvertInParams({
            tokenIn: tokenIn, amount: amountIn, target: FXUSD_SWAP_ROUTER, data: data, minOut: minOut, signature: ""
        });

        uint256 balanceBefore = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        IFxUSDDiamondV2(FXUSD_DIAMOND).depositToFxSave(params, tokenIn, 0, address(this));
        wrappedCollateralReceived =
            IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this)) - balanceBefore;

        if (wrappedCollateralReceived == 0) revert IZapErrors.NoWrappedCollateralReceived();
        if (wrappedCollateralReceived < minOut) {
            revert IZapErrors.SlippageTooHighWrappedCollateral(wrappedCollateralReceived, minOut);
        }
    }

    /// @notice Pull token, convert to wrapped collateral, and deposit into Genesis
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
        _safeApprove(IERC20(tokenIn), FXUSD_DIAMOND, 0);
    }

    /// @notice Deposit wrapped collateral into Genesis and validate shares
    /// @dev Confirms mint via receiver share balance delta; reverts `MintMismatchExpected` if mismatch.
    /// @param amount Amount of wrapped collateral to deposit
    /// @param receiver Address receiving Genesis shares
    function _depositToGenesis(uint256 amount, address receiver) internal {
        if (amount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 balance = IERC20(WRAPPED_COLLATERAL_ASSET).balanceOf(address(this));
        if (balance < amount) {
            revert IZapErrors.InsufficientBalance(balance, amount);
        }
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

    /// @notice Preview wrapped collateral output from a base asset amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewWrappedCollateralFromBase(uint256)
        external
        pure
        returns (uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Preview wrapped collateral output from a collateral amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewWrappedCollateralFromCollateral(uint256)
        external
        pure
        returns (uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Preview Genesis shares from a base asset amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewSharesFromBase(uint256)
        external
        pure
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Preview Genesis shares from a collateral amount
    /// @dev Not supported without a conversion oracle; kept for API parity
    function previewSharesFromCollateral(uint256)
        external
        pure
        returns (uint256 sharesOut, uint256 wrappedCollateralAmount)
    {
        revert IZapErrors.PreviewNotSupported();
    }

    /// @notice Preview the expected Genesis shares from a wrapped collateral amount
    /// @dev Genesis uses 1:1 deposits, so wrapped collateral amount equals shares
    /// @param wrappedCollateralAmount Amount of wrapped collateral
    /// @return sharesOut Expected Genesis shares that will be minted
    function previewSharesFromWrappedCollateral(uint256 wrappedCollateralAmount)
        external
        pure
        returns (uint256 sharesOut)
    {
        sharesOut = wrappedCollateralAmount; // 1:1 mapping
    }

    /// @notice Human-readable zap name based on the pegged token
    function zapName() external view returns (string memory) {
        address peggedToken = IGenesis(GENESIS).PEGGED_TOKEN();
        return string(abi.encodePacked("Genesis zap ", IERC20Metadata(peggedToken).name()));
    }

    // =============================================================
    // OWNER FUNCTIONS
    // =============================================================

    /// @notice Rescue stuck native asset
    function rescueNativeAsset() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
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

