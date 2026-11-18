// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit} from "./38016-h-02-mont-price-can-be-manipulated-to-earn-more-rewards-pash.sol";
contract Finding38016Test is Test {
    function test_exploit_spot_crash_pays_800_mont() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.mgr().lastReward(), 800 ether);
        assertEq(e.mont().balanceOf(address(e.player())), 9800 ether);
    }
}
