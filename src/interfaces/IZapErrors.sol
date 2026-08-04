// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Interface defining standard zap contract errors
interface IZapErrors {
    // ========== Common Errors ==========
    /// @notice Thrown when an amount is zero
    error ZeroAmount();

    /// @notice Thrown when an address is zero
    error ZeroAddress();

    /// @notice Thrown when a function is not found during a low-level call
    error FunctionNotFound();

    /// @notice Thrown when a view/preview path is intentionally unsupported (e.g. USDC zap without oracle)
    error PreviewNotSupported();

    /// @notice Thrown when an operation is unauthorized
    error Unauthorized();

    /// @notice Thrown when a zap internal conversion is called with an unsupported `tokenIn`
    /// @param tokenIn The token address that is not handled by this conversion path
    error ZapTokenInNotSupported(address tokenIn);

    /// @notice Thrown when an asset is not supported on the current chain
    /// @param asset The asset address that is unsupported
    /// @param chainId The current chain id
    error AssetNotSupportedOnChain(address asset, uint256 chainId);

    // ========== Genesis & Zap-Specific Errors ==========
    /// @notice Thrown when no collateral was received from a conversion
    error NoCollateralReceived();

    /// @notice Thrown when no wrapped collateral was received from a conversion
    error NoWrappedCollateralReceived();

    /// @notice Thrown when slippage exceeds the maximum allowed (generic fallback)
    error SlippageTooHigh();

    /// @notice Thrown when slippage exceeds the maximum allowed (more descriptive variant)
    error SlippageExceeded();

    /// @notice Thrown when the Genesis contract collateral token is invalid
    error InvalidGenesisCollateral();

    /// @notice Thrown when a deposit operation fails validation (not share/mint amount mismatch; see `MintMismatchExpected`)
    error DepositFailed();

    /// @notice Thrown when collateral address doesn't match expected address
    /// @param expected The expected collateral address
    /// @param actual The actual collateral address
    error CollateralMismatch(address expected, address actual);

    // ========== Minter / Genesis Zap Errors ==========
    /// @notice Thrown when the zapper's wrapped collateral token doesn't match the vault or minter
    /// @param expected The wrapped collateral token required by Minter or Genesis
    /// @param provided The wrapped collateral token compiled into the zapper
    error WrappedCollateralMismatch(address expected, address provided);

    /// @notice Thrown when a stability pool is not allowed/allowed
    error StabilityPoolNotAllowed();

    // ========== New Enhanced Slippage & Safety Errors (2026) ==========
    /// @notice Thrown when contract doesn't have enough balance before operation
    /// @param have Actual balance
    /// @param wanted Required balance
    error InsufficientBalance(uint256 have, uint256 wanted);

    /// @notice Thrown when minted amount does not match expectation (Genesis: shares vs deposit; Minter: return value vs balance delta)
    /// @param expected Expected amount (deposited wrapped / minter-reported mint)
    /// @param received Actual amount (share balance delta / balance delta)
    error MintMismatchExpected(uint256 expected, uint256 received);

    /// @notice Thrown when trying to rescue protected/critical tokens
    /// @param token The protected token address that was attempted to rescue
    error CannotRescueProtectedToken(address token);

    /// @notice Thrown when an ERC20 pull delivers a different amount than requested (fee-on-transfer / non-standard token)
    /// @param expected Amount requested via `transferFrom`
    /// @param received Actual balance increase observed on this contract
    error UnexpectedAmountIn(uint256 expected, uint256 received);

    /// @notice Thrown when native ETH transfer to owner fails (e.g. non-payable owner contract)
    error NativeTransferFailed();

    /// @notice Thrown when wrapped collateral output is below minimum acceptable amount
    /// @param received Actual wrapped collateral received
    /// @param minimum Minimum required by user
    /// @dev Single slippage bound for fx/USDC paths (no separate `SlippageTooHighCollateral`: input-token
    ///      slippage is enforced only via this wrapped min-out).
    error SlippageTooHighWrappedCollateral(uint256 received, uint256 minimum);

    /// @notice Thrown when final base asset-equivalent value is below minimum acceptable
    /// @param received Actual base asset value
    /// @param minimum Minimum base asset value required by user
    /// @dev Used by native-ETH Genesis zaps that can value the wrapped position in ETH; not used on USDC/fx
    ///      zaps without an on-chain base/collateral valuation oracle.
    error SlippageTooHighBaseAssetValue(uint256 received, uint256 minimum);
}
