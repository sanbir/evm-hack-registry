// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {CircomData} from "./types/CircomData.sol";

contract DeltaAmountCalculator {
    function calculateDeltaAmount(
        CircomData calldata circomData,
        int256[] memory approvalChanges,
        uint256 index
    ) internal pure returns (int256) {
        return
            (
                circomData.onChainCreation[index]
                    ? int256(0)
                    : circomData.amountChanges[index]
            ) + approvalChanges[index];
    }
}
