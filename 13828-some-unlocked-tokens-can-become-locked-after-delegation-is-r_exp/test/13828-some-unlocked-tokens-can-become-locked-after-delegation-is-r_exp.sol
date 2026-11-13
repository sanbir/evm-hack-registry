// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    TokenStateFixed
} from "./13828-some-unlocked-tokens-can-become-locked-after-delegation-is-r.sol";

contract Finding13828Test is Test {
    function test_reject_relocks_60e18_that_was_withdrawable() public {
        Exploit e = new Exploit();
        assertEq(e.buggy().balanceOf(address(e)), 0, "seed happens inside run");

        e.run();

        assertEq(e.withdrawableBefore(), 60 ether, "60e18 was withdrawable");
        assertEq(e.withdrawableAfter(), 0, "those 60e18 are not withdrawable");
        assertEq(e.reLocked(), 60 ether, "harm is 60e18");
        assertEq(e.purchasedAfter(), 100 ether, "purchased grew from 40e18 to 100e18");
        assertTrue(e.markedAllPurchased(), "mixed delegation was flagged purchased");
        assertTrue(e.transferOfNReverted(), "transfer of the 60e18 reverts");
        assertEq(e.buggy().balanceOf(address(e)), 100 ether, "the 60e18 never left");
        assertEq(e.buggy().balanceOf(address(0xCAFE)), 0, "sink received nothing");
    }

    function test_control_reject_leaves_60e18_unlocked() public {
        TokenStateFixed fixedTs = new TokenStateFixed();
        fixedTs.seed(address(this), 100 ether, 40 ether);
        assertEq(fixedTs.withdrawable(address(this)), 60 ether, "control starts with 60e18 free");

        uint256 id = fixedTs.propose(address(this), 100 ether);
        fixedTs.reject(id);

        assertEq(fixedTs.purchasedOf(address(this)), 40 ether, "only the purchased slice returns");
        assertEq(fixedTs.withdrawable(address(this)), 60 ether, "the 60e18 stay withdrawable");
        assertTrue(fixedTs.transfer(address(0xCAFE), 60 ether), "control transfer of 60e18 succeeds");
        assertEq(fixedTs.balanceOf(address(0xCAFE)), 60 ether, "sink received the 60e18");
        assertEq(fixedTs.balanceOf(address(this)), 40 ether, "the original 40e18 lock remains");
    }
}
