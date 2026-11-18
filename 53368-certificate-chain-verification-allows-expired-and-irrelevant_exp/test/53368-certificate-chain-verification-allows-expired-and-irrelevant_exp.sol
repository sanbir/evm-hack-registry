// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, PcsDao, PccsRouterFixed, EscrowFixed} from
    "./53368-certificate-chain-verification-allows-expired-and-irrelevant.sol";

contract Finding53368Test is Test {
    function test_exploit_expired_crl_pays_revoked_cert() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.accepted(), "revoked cert verified");
        assertTrue(e.crlExpired(), "crl expired");
        assertTrue(e.serialMissing(), "serial not in stored crl");
        assertEq(e.taken(), 5 ether, "bounty taken");
        assertEq(e.usd().balanceOf(address(e)), 5 ether, "attacker holds 5");
    }

    function test_control_expired_crl_keeps_the_bounty() public {
        Usd usd = new Usd();
        PcsDao dao = new PcsDao();
        PccsRouterFixed router = new PccsRouterFixed(dao);
        EscrowFixed escrow = new EscrowFixed(usd, router);
        dao.setCrl(1, abi.encode(uint256(1)), 0, bytes32(uint256(1)));
        usd.mint(address(escrow), 5 ether);
        vm.expectRevert();
        escrow.claim(0xDEAD);
        assertEq(usd.balanceOf(address(escrow)), 5 ether, "bounty stays");
        assertEq(usd.balanceOf(address(this)), 0, "caller got nothing");
    }
}
