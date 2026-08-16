// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title FxSAVE Constants
/// @notice Constants used by USDC/fxUSD/fxSAVE zap contracts
library FxSAVEConstants {
    /// @notice USDC token address (mainnet)
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @notice fxUSD token address (mainnet)
    address internal constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    /// @notice fxSAVE vault address (mainnet)
    address internal constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    /// @notice fxUSD Diamond contract address (handles deposits to fxSAVE)
    address internal constant FXUSD_DIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;
    /// @notice fxUSD swap router/converter address (for USDC and fxUSD deposits)
    address internal constant FXUSD_SWAP_ROUTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;

    /// @notice Selector of `MultiPathConverter.convert(address _tokenIn, uint256 _amount, uint256 _encoding, uint256[] _routes)`
    ///         on FXUSD_SWAP_ROUTER (= 0xed52d54c; `_encoding` is a packed ratio/route-length bitfield, not a min-out).
    /// @dev Currently unused at runtime: zaps deposit USDC/fxUSD with `tokenOut == tokenIn`, so the diamond skips the
    ///      router call (see `FxUSDZapBase_v1._convertHeldTokenToWrappedCollateral`). Kept for a future real-route payload.
    bytes4 internal constant CONVERT_SELECTOR = 0xed52d54c;
}
