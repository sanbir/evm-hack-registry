// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MockVault, FixedAdjustor} from
    "./56951-h-2-incorrect-implementation-of-erc4626viewadjustor-sherlock.sol";

contract Finding56951Test is Test {
    function test_exploit_depositor_overpays_19_steth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.charged(), 110 ether, "buggy toReal charges 110");
        assertEq(e.fair(), 90909090909090909090, "fair convertToShares is 90.909");
        assertEq(e.excess(), 19090909090909090910, "uncredited surplus");
        assertEq(e.token().balanceOf(address(e.surplus())), 19090909090909090910, "surplus holds the overcharge");
        assertEq(e.pool().credited(), 90909090909090909090, "position credit is only the fair amount");
        assertEq(e.token().balanceOf(address(e)), 0, "depositor paid the full charge");
    }

    function test_control_convertToShares_charges_fair() public {
        MockVault vault = new MockVault();
        FixedAdjustor fixedAdjustor = new FixedAdjustor(vault);
        uint256 nominal = 100 ether;
        uint256 fair = fixedAdjustor.toReal(address(0), nominal, false);
        uint256 expected = nominal * 1000 / 1100;
        assertEq(fair, expected, "swapped functions charge convertToShares");
        assertLt(fair, 110 ether, "fair charge is below the buggy 110");
    }
}
