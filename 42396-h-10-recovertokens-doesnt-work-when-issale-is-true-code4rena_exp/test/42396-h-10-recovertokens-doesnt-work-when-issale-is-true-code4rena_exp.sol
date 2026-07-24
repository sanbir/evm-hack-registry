// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42396-h-10-recovertokens-doesnt-work-when-issale-is-true-code4rena.sol";

/*//////////////////////////////////////////////////////////////
    Streaming -- recoverTokens broken after creatorClaimSoldTokens (H-10, #42396)
//////////////////////////////////////////////////////////////////////////*/
contract StreamingRecoverTokensSaleTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.depositTok().balanceOf(address(e.stream())), e.EXCESS(), "excess locked");
    }
}
