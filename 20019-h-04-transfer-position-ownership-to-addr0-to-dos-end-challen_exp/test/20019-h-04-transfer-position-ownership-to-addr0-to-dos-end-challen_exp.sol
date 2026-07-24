// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./20019-h-04-transfer-position-ownership-to-addr0-to-dos-end-challen.sol";

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin [H-04] — transferOwnership(address(0)) DoSes end().

    Driver re-asserts: end reverts, bid + challenger escrow stay in hub.
    Control: with a non-zero owner the same end() settles and releases the bid.
//////////////////////////////////////////////////////////////////////////*/
contract Addr0DoSTest is Test {
    function test_transferToZero_dos_end_locks_funds() public {
        Exploit exp = new Exploit();
        exp.run();

        assertTrue(exp.endReverted(), "end reverted");
        assertEq(exp.lockedBid(), exp.BID(), "bid locked");
        assertEq(exp.lockedCollateral(), 1e18, "collateral locked");
    }

    function test_saneOwner_end_settles() public {
        ZCHF zchf = new ZCHF();
        CollateralToken col = new CollateralToken();
        MintingHub hub = new MintingHub(zchf);
        Position position = new Position(address(this), address(hub), address(col));
        Bidder bidder = new Bidder(zchf, hub);
        Challenger challenger = new Challenger(col, hub);

        col.mint(address(position), 1e18);
        col.mint(address(challenger), 1e18);
        zchf.mint(address(bidder), 1060e18);

        uint256 id = challenger.challenge(position, 1e18);
        bidder.bid(id, 1060e18);

        // Owner stays non-zero — end succeeds (does not revert). Excess refund
        // of 7e18 goes to this owner; challenge is deleted.
        uint256 ownerBefore = zchf.balanceOf(address(this));
        hub.end(id, false);
        assertEq(zchf.balanceOf(address(this)) - ownerBefore, 7e18, "excess refunded to owner");
        // Challenge slot cleared (bidder zeroed by delete).
        assertEq(hub.challengeBidder(id), address(0), "challenge cleared");
    }
}
