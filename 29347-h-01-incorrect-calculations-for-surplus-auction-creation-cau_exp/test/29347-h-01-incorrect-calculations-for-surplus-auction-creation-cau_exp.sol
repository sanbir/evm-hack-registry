// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./29347-h-01-incorrect-calculations-for-surplus-auction-creation-cau.sol";

contract SurplusAuctionHundredWadTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.house().lastAmountToSell(), 297e18, "amountToSell inflated to 297");
        assertEq(e.house().auctionCount(), 1, "ghost auction created at 100% transfer");
        assertEq(e.accountingEngine().lastTransferAmount(), 3e18, "full surplus transferred");
        assertEq(e.safeEngine().coinBalance(e.extraReceiver()), 3e18);
    }

    function test_control_fixed_math_no_auction_at_100pct() public {
        // Control: with WAD instead of ONE_HUNDRED_WAD, 100% transfer creates no auction
        // amountToSell would be surplusAmount.wmul(WAD - WAD) = 0 and the branch is skipped.
        uint256 amountToSellFixed = (3e18 * (WAD - 1e18)) / WAD; // 0
        assertEq(amountToSellFixed, 0);
        bool wouldCreateAuction = (uint256(1e18) < WAD); // false
        assertFalse(wouldCreateAuction);
    }
}
