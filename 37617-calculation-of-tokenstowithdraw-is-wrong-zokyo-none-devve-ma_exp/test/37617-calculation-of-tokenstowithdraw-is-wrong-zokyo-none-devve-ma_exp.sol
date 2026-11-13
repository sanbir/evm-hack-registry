// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    AirdropToken,
    AirdropFixed
} from "./37617-calculation-of-tokenstowithdraw-is-wrong-zokyo-none-devve-ma.sol";

contract Finding37617Test is Test {
    function setUp() public {
        vm.warp(1_700_000_000);
    }

    function test_exploit_pays_minutes_instead_of_days() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.preview(), 2880 ether, "preview is 2880");
        assertEq(e.received(), 2880 ether, "paid 2880");
        assertEq(e.received() - 2 ether, 2878 ether, "2878 extra");
        assertEq(e.token().balanceOf(address(e.airdrop())), 0, "airdrop empty");
    }

    function test_control_days_pays_two() public {
        AirdropToken token = new AirdropToken();
        AirdropFixed fixedDrop = new AirdropFixed(token);
        fixedDrop.withdrawAirdropTokens();
        assertEq(token.balanceOf(address(this)), 2 ether, "fair payout is 2");
        assertEq(token.balanceOf(address(fixedDrop)), 2878 ether, "rest stays");
    }
}
