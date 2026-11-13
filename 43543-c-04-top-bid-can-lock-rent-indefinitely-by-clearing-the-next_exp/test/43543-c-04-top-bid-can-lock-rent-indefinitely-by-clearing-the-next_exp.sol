// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Token, AmAmm} from "./43543-c-04-top-bid-can-lock-rent-indefinitely-by-clearing-the-next.sol";

contract Finding43543Test is Test {
    address constant OUTBIDDER = 0x2222222222222222222222222222222222222222;

    function test_exploit_cancel_next_bid_keeps_fees() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.harvested(), 1000 ether, "fees");
        assertEq(e.feeToken().balanceOf(address(e)), 1000 ether, "attacker");
        assertEq(e.amAmm().getTopManager(), address(e), "seat");
        assertEq(e.amAmm().getNextManager(), address(0), "cleared");
        assertEq(e.bidToken().balanceOf(OUTBIDDER), 24 ether, "refund");
    }

    function test_control_k_epochs_promotes_outbidder_and_pays_fees() public {
        Token bidToken = new Token("BID");
        Token feeToken = new Token("FEE");
        AmAmm amAmm = new AmAmm(bidToken, feeToken, address(this), OUTBIDDER, 100, true);
        feeToken.mint(address(amAmm), 1000 ether);
        amAmm.poke();
        assertEq(amAmm.getTopManager(), OUTBIDDER, "promoted");
        amAmm.harvest();
        assertEq(feeToken.balanceOf(OUTBIDDER), 1000 ether, "fees");
        assertEq(feeToken.balanceOf(address(this)), 0, "manager");
    }
}
