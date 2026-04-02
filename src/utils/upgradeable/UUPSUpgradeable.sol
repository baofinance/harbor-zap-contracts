// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSUpgradeable as BaseUUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @dev UUPS wrapper that exposes initializer helpers for upgradeable contracts.
 *
 * This mirrors OpenZeppelin's UUPSUpgradeable behavior but keeps initializer
 * hooks available for upgradeable patterns used in this repo.
 */
abstract contract UUPSUpgradeable is Initializable, BaseUUPSUpgradeable {
    function __UUPSUpgradeable_init() internal onlyInitializing {}

    function __UUPSUpgradeable_init_unchained() internal onlyInitializing {}
}
