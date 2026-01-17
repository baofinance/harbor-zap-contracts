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

    // ========== Genesis & Zap-Specific Errors ==========
    /// @notice Thrown when no stETH was received from deposit/submit
    error NoStETHReceived();

    /// @notice Thrown when no fxSAVE was received from conversion
    error NoFxSaveReceived();

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
    /// @notice Thrown when wstETH address doesn't match Minter wrapped collateral token
    /// @param expected The expected wstETH address
    /// @param provided The provided wstETH address
    error WstETHMismatch(address expected, address provided);

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

    /// @notice Thrown when wstETH output is below minimum acceptable amount
    /// @param received Actual wstETH received
    /// @param minimum Minimum required by user
    error SlippageTooHighWstETH(uint256 received, uint256 minimum);

    /// @notice Thrown when final ETH-equivalent value is below minimum acceptable
    /// @param received Actual ETH value
    /// @param minimum Minimum ETH value required by user
    error SlippageTooHighETHValue(uint256 received, uint256 minimum);
}
