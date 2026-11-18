// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Riskiit, RiskiitFixed, Victim} from
    "./52922-unrestricted-username-registration-and-sybil-attack-risk-can.sol";

contract Finding52922Test is Test {
    function test_exploit_one_address_snipes_three_names() public {
        Exploit e = new Exploit();
        e.run();

        Riskiit r = e.riskiit();
        assertEq(r.registrationCount(address(e)), 3, "three names");
        assertEq(r.ownerOf("alice"), address(e), "alice sniped");
        assertEq(r.ownerOf("bob"), address(e), "bob sniped");
        assertEq(r.ownerOf("charlie"), address(e), "charlie sniped");
        assertTrue(e.victim().blocked(), "victim blocked");
    }

    function test_control_one_name_per_sender_and_age_sig() public {
        RiskiitFixed fixedReg = new RiskiitFixed();
        bytes memory sig = new bytes(65);
        fixedReg.registerPlayer("dave", true, sig);
        assertEq(fixedReg.ownerOf("dave"), address(this), "dave");

        vm.expectRevert(bytes("one name"));
        fixedReg.registerPlayer("erin", true, sig);

        RiskiitFixed other = new RiskiitFixed();
        // a different sender still cannot take a name this sender already owns on fixedReg;
        // a fresh registrar accepts a new sender's single name.
        other.registerPlayer("erin", true, sig);
        assertEq(other.ownerOf("erin"), address(this), "erin free");
        assertTrue(other.hasRegistered(address(this)), "marked");
    }
}
