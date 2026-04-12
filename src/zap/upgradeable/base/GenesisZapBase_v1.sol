// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title GenesisZapBase_v1
/// @notice Storage-free shared Genesis deposit + share validation for ETH and USDC genesis zaps.
abstract contract GenesisZapBase_v1 {
    function _genesisAddress() internal view virtual returns (address);

    function _wrappedCollateralAddress() internal view virtual returns (address);

    /// @notice Deposit wrapped collateral into Genesis and validate shares (1:1 expected).
    function _depositToGenesis(uint256 amount, address receiver) internal {
        address genesis = _genesisAddress();
        address wrapped = _wrappedCollateralAddress();

        if (amount == 0) revert IZapErrors.ZeroAmount();
        if (receiver == address(0)) revert IZapErrors.ZeroAddress();

        uint256 balance = IERC20(wrapped).balanceOf(address(this));
        if (balance < amount) revert IZapErrors.InsufficientBalance(balance, amount);

        uint256 sharesBefore = IGenesis(genesis).balanceOf(receiver);

        uint256 currentAllowance = IERC20(wrapped).allowance(address(this), genesis);
        if (currentAllowance < amount) {
            if (currentAllowance > 0) {
                IERC20(wrapped).approve(genesis, 0);
            }
            IERC20(wrapped).approve(genesis, type(uint256).max);
        }

        IGenesis(genesis).deposit(amount, receiver);

        uint256 sharesAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 sharesReceived = sharesAfter - sharesBefore;
        if (sharesReceived != amount) {
            revert IZapErrors.MintMismatchExpected(amount, sharesReceived);
        }
    }

    /// @dev Genesis vault: 1:1 shares for wrapped collateral amount (shared by ETH and USDC zaps).
    function _previewGenesisSharesFromWrappedCollateral(uint256 wrappedCollateralAmount)
        internal
        pure
        returns (uint256 sharesOut)
    {
        sharesOut = wrappedCollateralAmount;
    }

    /// @dev Human-readable label: `"Genesis zap "` + pegged token name from `IGenesis`.
    function _genesisZapDisplayName() internal view returns (string memory) {
        address peggedToken = IGenesis(_genesisAddress()).PEGGED_TOKEN();
        return string(abi.encodePacked("Genesis zap ", IERC20Metadata(peggedToken).name()));
    }
}
