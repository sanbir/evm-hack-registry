// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CollectionToken, Nft, Locker, ProtectedListingsFixed} from
    "./41749-h-11-user-can-unlock-protected-listing-without-paying-any-fe.sol";

contract Finding41749Test is Test {
    function test_exploit_unlocks_without_the_compounded_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fairPrice(), 402055890410801920, "fair");
        assertEq(e.priceAfter(), 0, "zeroed");
        assertEq(e.listings().feeBurned(), 0, "fee");
        assertEq(e.listings().paid(), 0.4 ether, "paid");
        assertEq(e.nft().ownerOf(0), address(e), "nft");
    }

    function test_control_dividing_by_the_factor_keeps_a_price() public {
        CollectionToken ct = new CollectionToken();
        Nft nft = new Nft();
        Locker locker = new Locker(nft, ct);
        ProtectedListingsFixed fixedL = new ProtectedListingsFixed(locker);
        ct.mint(address(this), 0.4 ether);
        fixedL.seed(address(nft), address(this));
        ct.approve(address(fixedL), 0.4 ether);
        fixedL.adjustPosition(address(nft), 0, -int256(0.4 ether));
        assertGt(fixedL.tokenTakenOf(address(nft), 0), 0, "principal remains");
        assertGt(fixedL.unlockPrice(address(nft), 0), 0, "fee remains");
        assertEq(nft.ownerOf(0), address(0), "nft stays");
    }
}
