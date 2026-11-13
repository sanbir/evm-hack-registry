// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, VestToken, FSDVesting} from "./42324-h-01-anyone-can-arbitrarily-call-fsdvestingupdatevestedtoken.sol";

contract Finding42324Test is Test {
    function test_stranger_inflates_the_cliff_claim() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token().balanceOf(address(e)), 100, "beneficiary took 100");
        assertEq(e.vest().amount(), 2000, "inflated");
        console2.log("claimed", e.token().balanceOf(address(e)));
        console2.log("vested amount", e.vest().amount());
    }

    function test_control_cliff_pays_5() public {
        VestToken token = new VestToken();
        FSDVesting vest = new FSDVesting(address(this), address(0xF5D), token);
        token.mint(address(vest), 100);
        assertEq(vest.calculateVestingClaim(), 5, "fair");
        uint256 paid = vest.claimVestedTokens();
        assertEq(paid, 5, "paid 5");
        assertEq(token.balanceOf(address(this)), 5, "beneficiary");
        assertEq(token.balanceOf(address(vest)), 95, "still locked");
        console2.log("control claim", paid);
    }
}
