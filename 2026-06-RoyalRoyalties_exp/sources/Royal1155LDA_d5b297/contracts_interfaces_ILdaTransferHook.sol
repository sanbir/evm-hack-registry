//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/**
 * @dev Interface for a contract with a callback hook to be called upon LDA transfers.
 */
interface ILdaTransferHook {

    function beforeLdaTransfer(
        address from,
        address to,
        uint128 tierId
    )
        external;
}
