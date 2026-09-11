// SPDX-License-Identifier: RECONSTRUCTED
pragma solidity ^0.5.16;

/**
 * RECONSTRUCTED teaching stub for Tectonic tUSDC
 * (0xB3bbf1bE947b245Aef26e3B6a9D777d7703F4c8e).
 */
contract TErc20Delegator {
    // Attacker calls borrow after TONIC oracle pump + tTONIC collateral post.
    function borrow(uint borrowAmount) external returns (uint) {
        // borrowInternal → comptroller.borrowAllowed → doTransferOut(msg.sender, borrowAmount)
        return 0; // line ~177 — entry used in PoC
    }
}
