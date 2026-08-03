// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

// @title FeeBatch
// @dev Struct for fee batches
library FeeBatch {
    struct Props {
        address[] feeTokens;
        uint256[] feeAmounts;
        uint256[] remainingAmounts;
        uint256 createdAt;
    }
}
