// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.5.0) (utils/ReentrancyGuardTransientUpgradeable.sol)

pragma solidity ^0.8.24;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/**
 * @dev Variant of {ReentrancyGuardTransient} that is upgradeable.
 *
 * NOTE: This variant only works on networks where EIP-1153 is available.
 *
 * _Available since v5.1._
 *
 * @custom:stateless
 */
abstract contract ReentrancyGuardTransientUpgradeable is Initializable, ReentrancyGuardTransient {
    function __ReentrancyGuardTransient_init() internal onlyInitializing {}

    function __ReentrancyGuardTransient_init_unchained() internal onlyInitializing {}
}
