// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Collateral,
    OptimisticOracle,
    LongShortPair
} from "./10705-c01-trapped-proposer-reward-openzeppelin-uma-audit-l2-bridge.sol";

contract Finding10705Test is Test {
    function test_exploit_prepaid_reward_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.collateral().balanceOf(address(e.pair())), e.REWARD(), "100 stuck");
        assertEq(e.claimed(), e.REWARD(), "only the expire-path reward was claimable");
    }

    function test_control_single_reward_is_paid() public {
        Collateral collateral = new Collateral();
        OptimisticOracle oracle = new OptimisticOracle(collateral);
        LongShortPair pair = new LongShortPair(collateral, oracle, 100 ether);
        collateral.mint(address(this), 100 ether);
        collateral.approve(address(pair), 100 ether);
        pair.expire();
        uint256 paid = oracle.claim(address(this));
        assertEq(paid, 100 ether, "proposer paid");
        assertEq(collateral.balanceOf(address(pair)), 0, "nothing trapped");
        assertEq(collateral.balanceOf(address(this)), 100 ether, "received the reward");
    }
}
