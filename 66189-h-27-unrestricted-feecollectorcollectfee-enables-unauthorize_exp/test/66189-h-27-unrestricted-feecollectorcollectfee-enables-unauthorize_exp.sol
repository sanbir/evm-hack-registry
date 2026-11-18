// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./66189-h-27-unrestricted-feecollectorcollectfee-enables-unauthorize.sol";

contract Finding66189Test is Test {
    function test_collectFee_pulls_victim_allowance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e.victim())), 0, "victim lost 1000");
        assertEq(e.token().balanceOf(address(e.collector())), 1000 ether, "collector holds it");
    }
}
