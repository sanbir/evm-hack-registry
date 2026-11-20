// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, VaultFixed} from
    "./58096-c-01-inflating-redemption-request-and-dos-in-the-vault-pasho.sol";

contract Finding58096Test is Test {
    address internal constant BOB = 0x2222222222222222222222222222222222222222;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_three_requests_pay_bob_nothing() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vault().totalRedemption(), 300 ether, "three queues");
        assertEq(e.vault().lastPaid(), 0, "bob paid nothing");
        assertEq(e.vault().balanceOf(BOB), 100 ether, "bob shares stuck");
        assertEq(e.marker().balanceOf(SINK), 50 ether, "missed 50");
    }

    function test_control_one_request_pays_bob_50() public {
        VaultFixed vault = new VaultFixed();
        vault.mintShares(address(this), 100 ether);
        vault.mintShares(BOB, 100 ether);
        vault.requestRedeem(100 ether, address(0x3333), address(this));
        bool second = true;
        try vault.requestRedeem(100 ether, address(0x4444), address(this)) {
            second = true;
        } catch {
            second = false;
        }
        assertFalse(second, "second request rejected");
        uint256 paid = vault.withdraw(BOB, 100 ether);
        assertEq(paid, 50 ether, "bob receives half of the remaining assets");
        assertEq(vault.balanceOf(BOB), 0, "bob shares burned");
    }
}
