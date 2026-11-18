// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, Accounting, ResponseModule, OracleFixed, Request, Response} from
    "./41804-a-users-balance-can-be-bonded-against-their-will-trailofbits.sol";

contract Finding41804Test is Test {
    address internal constant ALICE = 0x000000000000000000000000000000000000a11c;

    function test_exploit_bonds_alice_1000_without_consent() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.aliceFree(), 1000 ether, "before");
        assertEq(e.bondedAmt(), 1000 ether, "bonded");
        assertEq(e.accounting().freeBalance(ALICE), 0, "alice free");
        assertEq(e.accounting().bonded(ALICE), 1000 ether, "bond record");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "attacker holds 1000");
        assertEq(e.token().balanceOf(address(e.accounting())), 0, "accounting empty");
    }

    function test_control_unknown_dispute_module_cannot_bond_alice() public {
        Token token = new Token();
        Accounting accounting = new Accounting(token);
        ResponseModule module = new ResponseModule();
        address canonical = address(0xCAFE);
        OracleFixed oracle = new OracleFixed(canonical);
        accounting.setModule(address(module));
        token.mint(address(accounting), 1000 ether);
        accounting.credit(ALICE, 1000 ether);

        Request memory request = Request({
            responseModule: address(module),
            disputeModule: address(this),
            accounting: address(accounting),
            requestId: keccak256("alice-request")
        });
        Response memory response = Response({proposer: ALICE, requestId: keccak256("alice-request")});

        (bool ok,) = address(oracle).call(abi.encodeCall(oracle.proposeResponse, (request, response)));
        assertFalse(ok, "fixed oracle rejects");
        assertEq(accounting.freeBalance(ALICE), 1000 ether, "alice still free");
        assertEq(accounting.bonded(ALICE), 0, "nothing bonded");
        assertEq(token.balanceOf(address(accounting)), 1000 ether, "tokens stay");
        assertEq(token.balanceOf(address(this)), 0, "attacker got nothing");
    }
}
