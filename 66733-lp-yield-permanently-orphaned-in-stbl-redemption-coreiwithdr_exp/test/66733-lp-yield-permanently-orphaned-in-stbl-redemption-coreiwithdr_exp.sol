// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, YieldToken, YieldDistributor, Splitter, RedemptionCoreFixed} from
    "./66733-lp-yield-permanently-orphaned-in-stbl-redemption-coreiwithdr.sol";

contract Finding66733Test is Test {
    function test_exploit_withdraw_orphans_lp_yield() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.dist().earned(e.oldNft()), 500 ether, "stranded");
        assertEq(e.lpPaid(), 0, "lp got nothing");
        assertEq(e.token().balanceOf(address(e.dist())), 500 ether, "yield locked");
        assertFalse(e.oldClaimable(), "burned id not claimable");
    }

    function test_control_claim_before_withdraw_pays_lp() public {
        YieldToken token = new YieldToken();
        YieldDistributor dist = new YieldDistributor(token);
        Splitter spliter = new Splitter(dist);
        RedemptionCoreFixed core = new RedemptionCoreFixed(token, dist, spliter);
        core.seed(address(this), 10000 ether, 1);
        dist.accrue(1, 500 ether);
        core.withdraw(1000 ether);
        uint256 paid = core.harvest(address(this));

        assertEq(paid, 500 ether, "lp receives yield");
        assertEq(token.balanceOf(address(this)), 500 ether, "lp balance");
        assertEq(token.balanceOf(address(dist)), 0, "distributor empty");
        assertEq(dist.earned(1), 0, "nothing stranded");
    }
}
