// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42394-h-02-tokens-can-be-stolen-when-deposittoken-rewardtoken-code.sol";

/*//////////////////////////////////////////////////////////////
    Streaming -- recoverTokens double-count when deposit==reward (H-02, #42394)
//////////////////////////////////////////////////////////////////////////*/
contract StreamingSameTokenRecoverTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.stream())), e.DEPOSIT(), "deposits remain");
        assertEq(e.token().balanceOf(address(e)), e.REWARD(), "creator stole rewards");
    }
}
