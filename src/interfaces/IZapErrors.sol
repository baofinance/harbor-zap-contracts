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

    /// @notice Thrown when an operation is unauthorized
    error Unauthorized();

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

    /// @notice Thrown when a deposit operation fails or mint mismatch occurs
    error DepositFailed();

    /// @notice Thrown when collateral address doesn't match expected address
    /// @param expected The expected collateral address
    /// @param actual The actual collateral address
    error CollateralMismatch(address expected, address actual);

    // ========== Minter-Specific Errors ==========
    /// @notice Thrown when wrapped collateral address doesn't match expected address
    /// @param expected The expected wrapped collateral address
    /// @param provided The provided wrapped collateral address
    error WrappedCollateralMismatch(address expected, address provided);

    /// @notice Thrown when a mint operation fails
    error MintFailed();

    /// @notice Thrown when a stability pool is not allowed/allowed
    error StabilityPoolNotAllowed();

    // ========== New Enhanced Slippage & Safety Errors (2026) ==========
    /// @notice Thrown when contract doesn't have enough balance before operation
    /// @param have Actual balance
    /// @param wanted Required balance
    error InsufficientBalance(uint256 have, uint256 wanted);

    /// @notice Thrown when Genesis minted a different amount than expected
    /// @param expected Expected shares amount
    /// @param received Actual shares received
    error MintMismatchExpected(uint256 expected, uint256 received);

    /// @notice Thrown when trying to rescue protected/critical tokens
    /// @param token The protected token address that was attempted to rescue
    error CannotRescueProtectedToken(address token);

    /// @notice Thrown when wrapped collateral output is below minimum acceptable amount
    /// @param received Actual wrapped collateral received
    /// @param minimum Minimum required by user
    error SlippageTooHighWrappedCollateral(uint256 received, uint256 minimum);

    /// @notice Thrown when final base asset-equivalent value is below minimum acceptable
    /// @param received Actual base asset value
    /// @param minimum Minimum base asset value required by user
    error SlippageTooHighBaseAssetValue(uint256 received, uint256 minimum);
}
