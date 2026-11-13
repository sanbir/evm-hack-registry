// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, KHYPE, StakingManagerFixed, UserActor} from "./58553-h-01-buffer-silently-locks-staked-hype-in-contract-without-u.sol";

contract Finding58553Test is Test {
    function test_exploit_fifteen_hype_untracked() public {
        Exploit e = new Exploit();
        e.run{value: 20 ether}();
        assertEq(e.stuck(), 15 ether, "15 HYPE untracked");
        assertEq(e.manager().hypeBuffer(), 5 ether, "buffer left at 5");
        assertEq(address(e.manager()).balance, 20 ether, "HYPE never left");
        assertEq(e.l1().lastCDeposit(), 15e8, "cDeposit recorded 15 HYPE at 8 decimals");
    }

    function test_control_restores_buffer() public {
        KHYPE k = new KHYPE();
        StakingManagerFixed m = new StakingManagerFixed(k, address(this));
        UserActor user = new UserActor();
        m.fundBuffer{value: 20 ether}();
        k.mint(address(user), 15 ether);
        uint256 id = user.approveAndQueueFixed(k, m, 15 ether);
        m.cancelWithdrawal(address(user), id);
        assertEq(m.untracked(), 0, "nothing stuck");
        assertEq(m.hypeBuffer(), 20 ether, "buffer restored");
        assertEq(k.balanceOf(address(user)), 15 ether, "kHYPE returned");
    }
}
