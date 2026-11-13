// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Mini,
    SpokePoolFixed
} from "./56784-anyone-can-lock-relayer-refunds-and-contract-can-be-drained.sol";

contract Relayer {
    function claim(SpokePoolFixed pool, address token, address to) external {
        pool.claimRelayerRefund(token, to);
    }
}

contract Finding56784Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x2222222222222222222222222222222222222222;

    function test_exploit_drains_pool_and_zeroes_victim() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.victimRefundBefore(), 900 ether, "victim was owed 900");
        assertEq(e.victimRefundAfter(), 0, "victim credit zeroed");
        assertEq(e.attackerCreditAfterGrief(), 100 ether, "attacker credit was not cleared");
        assertEq(e.attackerHaul(), 900 ether, "attacker pulled 900");
        assertEq(e.poolLeft(), 0, "pool empty");
        assertEq(e.victimTokens(), 100 ether, "victim only received the attacker's 100 credit");
        assertEq(Mini(address(e.token())).balanceOf(ATTACKER), 900 ether, "EOA haul");
    }

    function test_control_zeroes_caller_and_stops() public {
        Mini token = new Mini();
        SpokePoolFixed pool = new SpokePoolFixed(token);
        Relayer attacker = new Relayer();
        Relayer victim = new Relayer();
        token.mint(address(pool), 1_000 ether);
        pool.recordRefund(address(attacker), 100 ether);
        pool.recordRefund(address(victim), 900 ether);

        attacker.claim(pool, address(token), ATTACKER);
        assertEq(token.balanceOf(ATTACKER), 100 ether, "one honest claim");
        assertEq(pool.relayerRefund(address(token), address(victim)), 900 ether, "victim credit untouched");
        vm.expectRevert(bytes("no refund"));
        attacker.claim(pool, address(token), ATTACKER);

        victim.claim(pool, address(token), VICTIM);
        assertEq(token.balanceOf(VICTIM), 900 ether, "victim still paid in full");
    }
}
