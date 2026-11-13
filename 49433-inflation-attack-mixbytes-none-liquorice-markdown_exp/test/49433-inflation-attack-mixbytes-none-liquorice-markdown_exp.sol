// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ExploitFixed} from "./49433-inflation-attack-mixbytes-none-liquorice-markdown.sol";

contract Finding49433Test is Test {
    function test_exploit_inflated_rate_takes_72_ether_from_victim() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rate(), 147573952589676412929, "rate");
        assertEq(e.victimShares(), 1, "one share");
        assertEq(e.profit(), 72713023705161793535, "profit");
        assertEq(e.dai().balanceOf(address(e.victim())), 0, "victim spent 293");
        assertEq(e.dai().balanceOf(address(e)), 300 ether + 72713023705161793535, "attacker balance");
    }

    function test_control_virtual_shares_give_victim_about_290() public {
        ExploitFixed fixedPool = new ExploitFixed();
        uint256 start = fixedPool.dai().balanceOf(address(fixedPool));
        (uint256 victimShares, uint256 endBalance) = fixedPool.run();

        assertGt(victimShares, 290 ether, "victim shares");
        assertLt(endBalance, start, "attacker does not profit");
    }
}
