// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, YieldToken, YieldDistributor, Splitter, RedemptionCoreFixed} from
    "./66732-pending-lp-yield-permanently-destroyed-in-stbl-redemption-co.sol";

contract Finding66732Test is Test {
    function test_exploit_deposit_destroys_pending_lp_yield() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.dist().earned(e.oldNft()), 100 ether, "stranded");
        assertEq(e.lpPaid(), 0, "lp got nothing");
        assertEq(e.token().balanceOf(address(e.dist())), 100 ether, "yield locked");
        assertFalse(e.oldClaimable(), "burned id not claimable");
        assertEq(e.core().rewardIndex(), 0, "index stale");
    }

    function test_control_claim_before_deposit_pays_lp() public {
        YieldToken token = new YieldToken();
        YieldDistributor dist = new YieldDistributor(token);
        Splitter spliter = new Splitter(dist);
        RedemptionCoreFixed core = new RedemptionCoreFixed(token, dist, spliter);
        address lp = address(uint160(0xB0B));
        core.seed(lp, 1000 ether, 1);
        dist.accrue(1, 100 ether);
        core.deposit(2, 1000 ether);
        uint256 paid = core.harvest(lp);

        assertEq(paid, 100 ether, "lp receives yield");
        assertEq(token.balanceOf(lp), 100 ether, "lp balance");
        assertEq(token.balanceOf(address(dist)), 0, "distributor empty");
        assertEq(dist.earned(1), 0, "nothing stranded");
    }
}
