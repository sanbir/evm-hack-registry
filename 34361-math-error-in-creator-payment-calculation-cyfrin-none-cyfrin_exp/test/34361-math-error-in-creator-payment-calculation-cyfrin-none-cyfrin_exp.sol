// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    USDC,
    TunnlTwitterOffers
} from "./34361-math-error-in-creator-payment-calculation-cyfrin-none-cyfrin.sol";

contract TunnlFixed is TunnlTwitterOffers {
    constructor(address _usdc) TunnlTwitterOffers(_usdc) {}

    function sendFunctionsRequest(uint256 offerId) external override returns (uint256 maxCreatorPayment) {
        maxCreatorPayment = uint256((s_offers[offerId].maxValueUsdc - s_offers[offerId].flatFeeUsdc) * 10000)
            / uint256(10000 + s_offers[offerId].advertiserFeePercentageBP);
        _payCreator(offerId, maxCreatorPayment);
    }
}

contract Finding34361Test is Test {
    function test_exploit_creator_is_paid_the_wrong_amount() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paidAmount(), 91_666_666, "paid 91666666");
        assertEq(e.fairAmount(), 100_000_000, "fair is 100000000");
        assertLt(e.paidAmount(), e.fairAmount(), "paid is below fair");
        emit log_named_uint("paid", e.paidAmount());
        emit log_named_uint("fair", e.fairAmount());
    }

    function test_control_advertiser_fee_pays_the_fair_amount() public {
        USDC usdc = new USDC();
        TunnlFixed offers = new TunnlFixed(address(usdc));
        offers.setConfig(2000, 1000);
        offers.openOffer(1, 110_000_000, 0, 1000, address(this));
        usdc.mint(address(offers), 110_000_000);

        uint256 quoted = offers.sendFunctionsRequest(1);
        assertEq(quoted, 100_000_000, "control quotes the fair offer");
        assertEq(usdc.balanceOf(address(this)), 100_000_000, "control pays the fair amount");
        assertEq(usdc.balanceOf(address(offers)), 10_000_000, "only the 10 percent advertiser fee remains");
        emit log_named_uint("control paid", usdc.balanceOf(address(this)));
    }
}
