// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Referrer, Referrals} from
    "./37791-h-02-referralsutilsupdatestartreferrerfeep-implements-wrong.sol";

contract Finding37791Test is Test {
    function test_exploit_above_cap_fee_pays_the_whole_budget() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.capRejected(), "cap rejected");
        assertEq(e.referrals().startReferrerFeeP(), 1e10, "stored 100%");
        assertEq(e.token().balanceOf(address(e.referrer())), 1000 ether, "referrer");
        assertEq(e.token().balanceOf(address(e.referrals())), 0, "pool empty");
    }

    function test_control_cap_is_accepted_and_100_percent_reverts() public {
        ERC20 token = new ERC20();
        Referrer r = new Referrer();
        Referrals refs = new Referrals(token, address(this), address(r), true);
        token.mint(address(refs), 1000 ether);
        refs.updateStartReferrerFeeP(refs.MAX_START_REFERRER_FEE_P());
        (bool ok,) = address(refs).call(
            abi.encodeWithSelector(Referrals.updateStartReferrerFeeP.selector, refs.PRECISION())
        );
        assertFalse(ok, "100% was accepted");
        refs.distributeReferralReward(1000 ether);
        assertEq(token.balanceOf(address(r)), 500 ether, "capped half");
        assertEq(token.balanceOf(address(refs)), 500 ether, "protocol keeps half");
    }
}
