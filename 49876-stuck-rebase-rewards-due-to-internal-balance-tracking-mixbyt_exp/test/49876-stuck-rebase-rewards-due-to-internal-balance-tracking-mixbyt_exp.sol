// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Deposits, RebaseToken} from "./49876-stuck-rebase-rewards-due-to-internal-balance-tracking-mixbyt.sol";

contract Finding49876Test is Test {
    function test_rebase_above_userSupply_stays_in_the_vault() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.got(), 100, "withdrawn");
        assertEq(e.stuck(), 25, "stuck");
        assertEq(e.fair(), 125, "share payout");
        console2.log("got", e.got());
        console2.log("stuck", e.stuck());
        console2.log("fair", e.fair());
    }

    function test_control_shares_pay_the_rebase() public {
        RebaseToken token = new RebaseToken();
        Deposits vault = new Deposits(token);
        token.mint(address(this), 100);
        vault.deposit(address(token), 100);
        token.rebase(address(vault), 25);

        uint256 paid = vault.withdrawShares(address(token));
        assertEq(paid, 125, "principal plus rebase");
        assertEq(token.balanceOf(address(vault)), 0, "nothing stuck");
        console2.log("control paid", paid);
    }
}
