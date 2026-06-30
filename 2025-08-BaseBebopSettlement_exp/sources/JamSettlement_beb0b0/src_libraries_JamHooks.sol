// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../libraries/JamInteraction.sol";

/// @title JamHooks
/// @notice JamHooks is a library for managing pre and post interactions
library JamHooks {

    bytes32 internal constant EMPTY_HOOKS_HASH = bytes32(0);

    /// @dev Data structure for pre and post interactions
    struct Def {
        JamInteraction.Data[] beforeSettle;
        JamInteraction.Data[] afterSettle;
    }

    function hash(Def memory hooks) internal pure returns (bytes32) {
        if (hooks.afterSettle.length == 0 && hooks.beforeSettle.length == 0){
            return EMPTY_HOOKS_HASH;
        }
        return keccak256(abi.encode(hooks));
    }
}
