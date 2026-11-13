// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RToken, DETokenFixed, StabilityPoolFixed} from
    "./66498-c-01-update-inside-detoken-causes-incorrect-accounting-pash.sol";

contract Finding66498Test is Test {
    function test_exploit_deposit_mints_210_extra_interest() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.redeemed(), 2310 ether, "redeemed 2310");
        assertEq(e.booked(), 2100 ether, "books only 2100");
        assertEq(e.rToken().balanceOf(address(e)), 2310 ether, "user holds 2310");
        assertEq(e.rToken().balanceOf(address(e.pool())), 18690 ether, "pool short 210");
    }

    function test_control_skip_mint_in_update_pays_2100() public {
        RToken rToken = new RToken();
        DETokenFixed fixedToken = new DETokenFixed();
        StabilityPoolFixed pool = new StabilityPoolFixed(rToken, fixedToken);
        fixedToken.initialize(address(pool));
        rToken.setUserIndex(address(this), 11 * 1e27 / 10);
        rToken.mint(address(this), 1000 ether);
        rToken.mint(address(pool), 20000 ether);
        rToken.approve(address(pool), type(uint256).max);
        fixedToken.seed(address(this), 1000 ether, 1e27);
        pool.deposit(1000 ether);
        assertEq(fixedToken.balanceOf(address(this)), 2100 ether, "fair tokens");
        assertEq(fixedToken.interestMinted(), 0, "no second interest");
        pool.redeem();
        assertEq(rToken.balanceOf(address(this)), 2100 ether, "fair redeem");
        assertEq(rToken.balanceOf(address(pool)), 18900 ether, "pool keeps the 210");
    }
}
