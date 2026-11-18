// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    DealToken,
    EntityType,
    Exploit,
    QuadrataKYCVerifierFixed,
    QuadrataReader
} from "./37958-bypass-of-entitytype-check-when-null-attribute-is-returned-b.sol";

contract Finding37958Test is Test {
    function test_null_business_attribute_receives_individual_allocation() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.dealToken().balanceOf(address(e)), 1000 ether, "attacker received the restricted allocation");
        assertEq(e.reader().businessOf(address(e)), bytes32(0), "business attribute was null");
        assertTrue(e.verifier().eligible(address(e)), "null attribute was marked eligible");
    }

    function test_control_null_attribute_reverts_and_business_cannot_enter() public {
        QuadrataReader reader = new QuadrataReader();
        DealToken deal = new DealToken();
        QuadrataKYCVerifierFixed fixedVerifier = new QuadrataKYCVerifierFixed(reader, deal, EntityType.Individual);
        deal.setMinter(address(fixedVerifier));
        reader.setDID(address(this), bytes32("did"));
        vm.expectRevert(bytes("null attribute"));
        fixedVerifier.verifyEligibility(address(this));
        assertEq(deal.balanceOf(address(this)), 0, "null attribute receives nothing");

        reader.setBusiness(address(this), bytes32(uint256(1)));
        vm.expectRevert();
        fixedVerifier.verifyEligibility(address(this));
        assertEq(deal.balanceOf(address(this)), 0, "a business does not receive an Individual allocation");
    }
}
