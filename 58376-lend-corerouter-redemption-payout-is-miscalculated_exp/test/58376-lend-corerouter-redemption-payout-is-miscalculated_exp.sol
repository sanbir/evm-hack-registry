// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Exploit, CoreRouter, LToken, LendStorage, MockToken} from
    "./58376-lend-corerouter-redemption-payout-is-miscalculated.sol";

// LEND H-7 (finding 58376): CoreRouter.redeem pays the user a precomputed
// `expectedUnderlying` (from exchangeRateStored) without checking the actual
// amount received from LToken.redeem(). A redemption fee not reflected in the
// stored rate makes CoreRouter overpay and drain its reserve of other users' funds.
contract Finding58376Test is Test {
    function test_exploit_redeemOverpay_drainsReserve() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("paid to user (expectedUnderlying)", e.expectedPaid());
        emit log_named_uint("actually received from LToken", e.actualReceived());
        emit log_named_uint("reserve drained", e.reserveDrained());

        assertEq(e.expectedPaid(), 200 ether, "user paid full pre-fee amount");
        assertEq(e.actualReceived(), 180 ether, "CoreRouter received only post-fee amount");
        assertGt(e.expectedPaid(), e.actualReceived(), "CoreRouter overpaid");
        assertEq(e.reserveDrained(), 20 ether, "reserve drained by the shortfall");
    }
}
