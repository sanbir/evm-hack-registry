// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./28832-h-01-primesol-user-can-claim-prime-token-without-having-any.sol";
contract Venus28832Test is Test {
    function test_claimsPrimeWithNoXVSStaked() public {
        Exploit e = new Exploit(); e.run();
        assertEq(e.stakeWhenClaimed(), 0);
        (bool exists, bool irrevocable) = e.prime().tokens(address(e));
        assertTrue(exists); assertFalse(irrevocable);
    }
}
