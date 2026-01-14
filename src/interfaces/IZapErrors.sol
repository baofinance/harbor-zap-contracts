// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Interface defining standard zap contract errors
interface IZapErrors {
    // ========== Common Errors ==========
    
    /// @notice Thrown when an amount is zero
    error ZeroAmount();
    
    /// @notice Thrown when an address is invalid (zero address)
    error InvalidAddress();
    
    /// @notice Thrown when an address is zero
    error ZeroAddress();
    
    /// @notice Thrown when a function is not found during a low-level call
    error FunctionNotFound();
    
    /// @notice Thrown when an operation is unauthorized
    error Unauthorized();
    
    // ========== Genesis-Specific Errors ==========
    
    /// @notice Thrown when no stETH was received from deposit
    error NoStETHReceived();
    
    /// @notice Thrown when slippage exceeds the maximum allowed
    error SlippageTooHigh();
    
    /// @notice Thrown when slippage exceeds the maximum allowed
    error SlippageExceeded();
    
    /// @notice Thrown when the Genesis contract collateral token is invalid
    error InvalidGenesisCollateral();
    
    /// @notice Thrown when a deposit operation fails
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
}
