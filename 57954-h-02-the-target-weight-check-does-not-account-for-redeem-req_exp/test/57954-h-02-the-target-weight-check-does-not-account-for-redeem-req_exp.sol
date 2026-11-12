// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BasketFixed, MockToken} from "./57954-h-02-the-target-weight-check-does-not-account-for-redeem-req.sol";

contract TargetWeightTest is Test {
    function test_exploit_rebalanceRejectsAndLocks600() public {
        Exploit e = new Exploit();
        e.run();

        assertFalse(e.rebalanceOk(), "rejected");
        assertEq(e.weightBps(), 1600, "16 percent");
        assertEq(e.deviationBps(), 600, "6 percent");
        assertEq(e.locked(), 1600 ether, "1000 inventory plus 600 redeem");
        assertEq(e.token().balanceOf(address(e)), 0, "redeemer unpaid");
    }

    function test_control_subtractsPendingRedeemAndPays600() public {
        MockToken token = new MockToken();
        BasketFixed basket = new BasketFixed(address(token));
        basket.queueRedeem(address(this), 600 ether);

        bool ok = basket.proposeRebalance();
        assertTrue(ok, "control passes");
        assertEq(token.balanceOf(address(this)), 600 ether, "redeem paid");
        assertEq(token.balanceOf(address(basket)), 1000 ether, "only the free inventory remains");
    }
}
