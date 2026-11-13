// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Mini, LOBFixed, Trader} from "./56840-incorrect-handling-of-fee-on-transfer-tokens-mixbytes-none-x.sol";

contract Finding56840Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    function test_exploit_withdraws_more_than_delivered() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.attackerCredit(), 10_000 ether, "credited the full 10000");
        assertEq(e.fairDelivered(), 9_000 ether, "pool only received 9000");
        assertEq(e.excess(), 1_000 ether, "1000 withdrawn from other traders");
        assertEq(e.victimShort(), 1_500 ether, "victim credit exceeds the tokens left");
        assertEq(Mini(address(e.token())).balanceOf(ATTACKER), 1_000 ether, "attacker received the 1000");
        assertEq(e.poolLeft(), 3_500 ether, "pool cannot cover the victim");
    }

    function test_control_reverts_on_fee_token() public {
        Mini token = new Mini();
        LOBFixed lob = new LOBFixed(token);
        token.setLob(address(lob));
        Trader attacker = new Trader();
        token.mint(address(attacker), 10_000 ether);
        token.mint(address(lob), 5_000 ether);

        vm.expectRevert(bytes("fee-on-transfer"));
        attacker.depositFixed(token, lob, 10_000 ether);

        assertEq(token.balanceOf(address(lob)), 5_000 ether, "honest balance untouched");
        assertEq(token.balanceOf(ATTACKER), 0, "nothing extracted");
    }
}
