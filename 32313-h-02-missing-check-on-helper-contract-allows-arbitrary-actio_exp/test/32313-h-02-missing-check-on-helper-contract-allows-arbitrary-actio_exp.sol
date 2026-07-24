// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32313-h-02-missing-check-on-helper-contract-allows-arbitrary-actio.sol";

contract MaliciousMarketHelperTest is Test {
    function test_malicious_helper_steals_victim_collateral() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.bigBang().collateralOf(exp.VICTIM()), 0, "victim coll drained");
        assertEq(
            exp.bigBang().freeCollateral(exp.ATTACKER()),
            exp.COLLATERAL(),
            "attacker received collateral"
        );
    }
}
