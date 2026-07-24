// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42395-h-04-improper-implementation-of-arbitrarycall-allows-protoco.sol";

/*//////////////////////////////////////////////////////////////
    Streaming -- arbitraryCall drains user allowance after incentive claim (H-04, #42395)
//////////////////////////////////////////////////////////////////////////*/
contract StreamingArbitraryCallTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(e.ATTACKER()), e.ALICE_REMAINING(), "attacker received Alice residual");
        assertEq(e.usdc().balanceOf(address(e.alice())), 0, "Alice drained");
    }
}
