// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Usd, LendingPool, RTokenFixed, FreshAccount} from
    "./66155-c-01-users-can-steal-lending-interest-pashov-audit-group-non.sol";

contract Finding66155Test is Test {
    function test_exploit_transfer_steals_100_crvusd_interest() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.fair(), 300 ether, "fair claim");
        assertEq(e.inflated(), 400 ether, "inflated");
        assertEq(e.paid(), 400 ether, "paid");
        assertEq(e.usd().balanceOf(address(e)), 400 ether, "attacker holds 400");
        assertEq(e.usd().balanceOf(address(e.rtoken())), 0, "pool empty");
    }

    function test_control_accrue_on_transfer_pays_300() public {
        Usd usd = new Usd();
        LendingPool pool = new LendingPool();
        RTokenFixed token = new RTokenFixed(address(pool), usd);
        FreshAccount fresh = new FreshAccount();

        pool.setIndex(1e27);
        usd.mint(address(this), 200 ether);
        usd.approve(address(token), type(uint256).max);
        token.deposit(address(this), 100 ether);
        pool.setIndex(2e27);
        token.deposit(address(fresh), 100 ether);
        usd.mint(address(token), 200 ether);

        uint256 fair = token.balanceOf(address(this)) + token.balanceOf(address(fresh));
        fresh.dump(token, address(this));
        uint256 paid = token.withdraw(address(this));

        assertEq(fair, 300 ether, "fair");
        assertEq(paid, 300 ether, "control pays fair 300");
        assertEq(usd.balanceOf(address(this)), 300 ether, "receiver");
        assertEq(usd.balanceOf(address(token)), 100 ether, "reserve remains");
    }
}
