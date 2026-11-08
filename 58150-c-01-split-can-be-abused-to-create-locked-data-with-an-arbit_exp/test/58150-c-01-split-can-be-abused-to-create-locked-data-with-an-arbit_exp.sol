// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    VotingEscrowFixed
} from "./58150-c-01-split-can-be-abused-to-create-locked-data-with-an-arbit.sol";

contract Finding58150Test is Test {
    function test_exploit_split_inflates_lock_and_claim() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.inflatedAmount(), int128(uint128(10_000 ether)), "locked 10000");
        assertLt(e.negativeAmount(), 0, "sibling is negative");
        assertEq(uint256(uint128(-e.negativeAmount())), 9_900 ether, "sibling is -9900");
        assertEq(e.lockToken().balanceOf(address(e.ve())), 200 ether, "only 200 was deposited");
        assertEq(e.gov().yesVotes(), 10_000 ether, "voted with 10000");
        assertEq(e.gov().noVotes(), 100 ether, "honest voted 100");
        assertEq(e.bribe().balanceOf(address(this)), 10_000 ether, "claimed the inflated amount");
    }

    function test_control_rejects_oversized_split_and_conserves_a_fair_one() public {
        Token lock = new Token("Lock", "LOCK");
        VotingEscrowFixed ve = new VotingEscrowFixed(lock);
        lock.mint(address(this), 100 ether);
        lock.approve(address(ve), type(uint256).max);
        uint256 id = ve.create_lock(100 ether);

        vm.expectRevert(bytes("amount"));
        ve.split(id, 10_000 ether);

        (int128 still, ) = ve.locked(id);
        assertEq(still, int128(uint128(100 ether)), "original lock unchanged");

        (uint256 a, uint256 b) = ve.split(id, 40 ether);
        (int128 left, ) = ve.locked(a);
        (int128 right, ) = ve.locked(b);
        assertEq(uint256(uint128(left)) + uint256(uint128(right)), 100 ether, "children sum to the parent");
        assertEq(uint256(uint128(right)), 40 ether, "requested leg");
    }
}
