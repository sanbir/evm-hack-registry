// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CollectionToken, ProtectedListingsFixed} from
    "./41745-h-7-user-can-pay-less-protected-listing-fees-sherlock-flayer.sol";

contract Finding41745Test is Test {
    function test_exploit_second_unlock_pays_less_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.fee0(), 0.402 ether, "first");
        assertEq(e.fee1(), 0.401 ether, "second");
        assertEq(e.kept(), 0.001 ether, "kept");
        assertEq(e.token().balanceOf(address(e)), 0.001 ether, "balance");
    }

    function test_control_checkpoint_before_decrement_charges_both() public {
        CollectionToken token = new CollectionToken();
        ProtectedListingsFixed fixedL = new ProtectedListingsFixed(token);
        fixedL.createTwo(address(this));
        uint256 fair = 0.804 ether;
        token.mint(address(this), fair);
        token.approve(address(fixedL), fair);
        uint256 a = fixedL.unlockProtectedListing(address(0), 0, true);
        uint256 b = fixedL.unlockProtectedListing(address(0), 1, true);
        assertEq(a, 0.402 ether, "fee a");
        assertEq(b, 0.402 ether, "fee b");
        assertEq(token.balanceOf(address(this)), 0, "nothing kept");
        assertEq(fixedL.feesTaken(), fair, "protocol paid in full");
    }
}
