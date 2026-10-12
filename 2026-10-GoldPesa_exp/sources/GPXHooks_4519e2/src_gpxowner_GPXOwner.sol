// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract GPXOwner is Ownable2Step {

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    constructor(address _multiSigWallet) Ownable(_multiSigWallet) {}

    // ============================
    // ======= ETH GUARD ==========
    // ============================

    /**
     * @dev Fallback function to ensure ETH is never accepted.
     */
    receive() external payable {
        revert("ETH not accepted");
    }

    /**
     * @dev Fallback function to ensure ETH with data is never accepted.
     */
    fallback() external payable {
        revert("ETH not accepted");
    }
}