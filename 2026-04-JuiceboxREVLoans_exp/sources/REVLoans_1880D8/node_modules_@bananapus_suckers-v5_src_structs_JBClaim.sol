// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBLeaf} from "./JBLeaf.sol";

/// @custom:member token The token to claim.
/// @custom:member leaf The leaf to claim from.
/// @custom:member proof The proof to claim with. Must be of length `JBSucker._TREE_DEPTH`.
struct JBClaim {
    address token;
    JBLeaf leaf;
    bytes32[32] proof;
}
