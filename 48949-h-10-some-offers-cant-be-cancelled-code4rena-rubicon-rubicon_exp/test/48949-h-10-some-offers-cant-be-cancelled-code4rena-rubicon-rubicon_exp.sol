// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./48949-h-10-some-offers-cant-be-cancelled-code4rena-rubicon-rubicon.sol";

/* Rubicon H-10 — some SimpleMarket offers can't be cancelled (Code4rena 2023-04) */
contract PoC_48949 is Test {
    function test_offersCantBeCancelled() public {
        Exploit e = new Exploit();
        e.run();

        // Harm: maker's pay_gem is locked; cancel failed
        assertEq(e.payToken().balanceOf(address(e.market())), e.LOCKED());
        assertEq(e.payToken().balanceOf(address(e.maker())), 0);
        assertGt(e.market().getOfferPayAmt(e.offerId()), 0);

        // Control: cancel on a SimpleMarket offer reverts with "can't hide" (via tryCancel).
        Maker m = e.maker();
        e.payToken().mint(address(m), 1e18);
        uint256 id2 = m.placeOffer(1e18, address(e.buyToken()), 1e18);
        assertFalse(m.tryCancel(id2), "second cancel also fails");
        // Direct cancel by owner reverts with the blamed reason:
        RubiconMarket market = e.market();
        vm.prank(address(m));
        vm.expectRevert(bytes("can't hide"));
        market.cancel(id2);
    }
}
