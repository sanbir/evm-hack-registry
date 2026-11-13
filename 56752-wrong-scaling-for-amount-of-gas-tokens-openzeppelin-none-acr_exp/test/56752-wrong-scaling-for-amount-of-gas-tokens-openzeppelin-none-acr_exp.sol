// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, GasScaled} from "./56752-wrong-scaling-for-amount-of-gas-tokens-openzeppelin-none-acr.sol";

contract Finding56752Test is Test {
    address internal constant FUNDER = 0x5555555555555555555555555555555555555555;
    address internal constant INBOX = 0x4444444444444444444444444444444444444444;

    function test_exploit_withdraws_unscaled_fee() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.gasTerm(), 1e16, "5 gwei * 2_000_000");
        assertEq(e.submissionCost(), 1e16, "submission");
        assertEq(e.requiredL1CallValue(), 2e16, "18-decimal fee");
        assertEq(e.fair(), 20_000, "6-decimal fee");
        assertEq(e.pulled(), 2e16, "withdrawn");
        assertEq(e.pulled() / e.fair(), 1e12, "scale");
        assertEq(e.balanceOf(FUNDER), 0, "funder drained");
        assertEq(e.balanceOf(INBOX), 2e16, "inbox took the unscaled fee");
    }

    function test_control_scales_before_withdraw() public {
        GasScaled fixedAdapter = new GasScaled();
        fixedAdapter.run();

        assertEq(fixedAdapter.pulled(), 20_000, "control withdraws 20000");
        assertEq(fixedAdapter.balanceOf(INBOX), 20_000, "inbox fair");
        assertEq(fixedAdapter.balanceOf(FUNDER), 2e16 - 20_000, "funder keeps the rest");
    }
}
