// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    BondEscalationResolutionModuleFixed,
    Dispute,
    ERC20,
    Exploit,
    Request
} from "./41793-arbitrary-request-data-can-be-provided-to-module-functions-i.sol";

contract Finding41793Test is Test {
    function test_fake_request_takes_the_usdc_bond() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(e)), 1000 ether, "attacker received the 1000 USDC bond");
        assertEq(e.usdc().balanceOf(address(e.module())), 0, "module is empty");
        assertEq(e.module().activeToken(), address(e.evil()), "pledge was denominated in EVIL");
    }

    function test_control_mismatched_request_reverts() public {
        ERC20 usdc = new ERC20("USD Coin", "USDC");
        ERC20 evil = new ERC20("Attacker Bond", "EVIL");
        bytes32 realId = keccak256("honest-pricing-request");
        BondEscalationResolutionModuleFixed fixedModule = new BondEscalationResolutionModuleFixed(
            usdc, Dispute({requestId: realId, proposer: address(0xBEEF)}), address(usdc), 1
        );
        usdc.mint(address(fixedModule), 1000 ether);
        evil.mint(address(this), 1 ether);
        evil.approve(address(fixedModule), 1);
        Request memory fake = Request({requestId: keccak256("fake-request"), bondToken: address(evil), timeUntilDeadline: block.timestamp});
        Dispute memory d = Dispute({requestId: realId, proposer: address(0xBEEF)});
        vm.expectRevert(bytes("request mismatch"));
        fixedModule.pledgeAgainstDispute(fake, d, 1);
        assertEq(usdc.balanceOf(address(fixedModule)), 1000 ether, "bond stays escrowed");
    }
}
