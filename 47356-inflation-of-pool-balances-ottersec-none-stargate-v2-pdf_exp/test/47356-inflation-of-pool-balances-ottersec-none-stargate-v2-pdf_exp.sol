// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ControlPool, MockToken} from "./47356-inflation-of-pool-balances-ottersec-none-stargate-v2-pdf.sol";

contract PoolBalanceInflationTest is Test {
    uint256 internal constant AMOUNT = 1000 ether;
    uint256 internal constant GIFT = 1000 ether;

    function test_exploit_redeemPaysTheInflatedBalance() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.inflated(), AMOUNT + GIFT, "inflated");
        assertEq(e.vulnPaid(), AMOUNT + GIFT, "vuln paid");
        assertEq(e.extra(), GIFT, "extra");
        assertEq(e.controlQuoted(), AMOUNT, "control quote");
        assertEq(e.controlPaid(), AMOUNT, "control paid");
        assertEq(e.controlLeft(), GIFT, "control leftover");
        assertEq(e.token().balanceOf(address(e)), AMOUNT * 2 + GIFT, "lp ended with deposit plus extra");
    }

    function test_control_internalBalanceDoesNotPayTheGift() public {
        MockToken token = new MockToken();
        ControlPool pool = new ControlPool(address(token));
        token.mint(address(this), AMOUNT);
        token.mint(address(this), GIFT);
        token.approve(address(pool), AMOUNT);
        pool.deposit(AMOUNT, address(this));
        token.transfer(address(pool), GIFT);

        assertEq(pool.poolBalance(), AMOUNT, "quote");
        uint256 paid = pool.redeem(AMOUNT, address(this));
        assertEq(paid, AMOUNT, "paid");
        assertEq(token.balanceOf(address(pool)), GIFT, "gift stays");
        assertEq(token.balanceOf(address(this)), AMOUNT, "redeemer did not receive the gift");
    }
}
