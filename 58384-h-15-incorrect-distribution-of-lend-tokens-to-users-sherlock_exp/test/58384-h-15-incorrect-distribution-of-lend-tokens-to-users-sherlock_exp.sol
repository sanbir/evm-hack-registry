// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, LendToken, LendStorageFixed} from
    "./58384-h-15-incorrect-distribution-of-lend-tokens-to-users-sherlock.sol";

contract Finding58384Test is Test {
    function test_exploit_reward_includes_the_new_principal() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.paid(), 200 ether, "paid");
        assertEq(e.lend().balanceOf(address(e)), 200 ether, "balance");
    }

    function test_control_distributes_before_the_new_principal() public {
        LendToken lend = new LendToken();
        LendStorageFixed fixedS = new LendStorageFixed(lend);
        fixedS.seed(address(this), 100 ether);
        uint256 paid = fixedS.handleBorrow(address(this), 100 ether);
        assertEq(paid, 100 ether, "only the open principal");
        assertEq(lend.balanceOf(address(this)), 100 ether, "balance");
        (,, uint256 principle,) = fixedS.row(address(this));
        assertEq(principle, 200 ether, "principal updated after");
    }
}
