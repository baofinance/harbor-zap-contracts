// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ISTETHV2, IStETHView} from "src/interfaces/IStETH.sol";
import {IWstETHWrapV2, IWstETHView} from "src/interfaces/IWstETH.sol";
import {IZapErrors} from "src/interfaces/IZapErrors.sol";

/// @title StETHZapBase_v1
/// @notice Internal helpers for Lido stETH → wstETH conversion paths (Genesis + Minter zaps).
abstract contract StETHZapBase_v1 {
    using SafeERC20 for IERC20;

    /// @dev Native base asset (ETH) credited to this contract → collateral (e.g. stETH) via Lido `submit`.
    function _convertBaseAssetToCollateral(address collateral, address lidoReferral, uint256 ethAmount)
        internal
        returns (uint256 collateralReceived)
    {
        uint256 beforeB = IERC20(collateral).balanceOf(address(this));
        ISTETHV2(collateral).submit{value: ethAmount}(lidoReferral);
        collateralReceived = IERC20(collateral).balanceOf(address(this)) - beforeB;
        if (collateralReceived == 0) revert IZapErrors.NoCollateralReceived();
    }

    /// @dev Collateral already held by this contract → wrapped collateral (e.g. wstETH).
    function _wrapCollateralToWrappedCollateral(address collateral, address wrapped, uint256 collateralAmount)
        internal
        returns (uint256 wrappedReceived)
    {
        IERC20(collateral).forceApprove(wrapped, collateralAmount);
        uint256 wBefore = IERC20(wrapped).balanceOf(address(this));
        IWstETHWrapV2(wrapped).wrap(collateralAmount);
        wrappedReceived = IERC20(wrapped).balanceOf(address(this)) - wBefore;
        if (wrappedReceived == 0) revert IZapErrors.NoWrappedCollateralReceived();
        IERC20(collateral).forceApprove(wrapped, 0);
    }

    function _permitCollateral(
        address collateral,
        address owner,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        IERC20Permit(collateral).permit(owner, address(this), amount, deadline, v, r, s);
    }

    /// @dev View-only: base asset amount → wrapped collateral if routed via collateral (Lido + wrap math).
    function _estimateWrappedCollateralFromBase(address collateral, address wrapped, uint256 baseAssetAmount)
        internal
        view
        returns (uint256 wrappedCollateralAmount)
    {
        uint256 collateralShares = IStETHView(collateral).getSharesByPooledEth(baseAssetAmount);
        uint256 collateralAmount = IStETHView(collateral).getPooledEthByShares(collateralShares);
        wrappedCollateralAmount = IWstETHView(wrapped).getWstETHByStETH(collateralAmount);
    }
}
