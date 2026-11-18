// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20, Vault, Buyer} from
    "./48700-vaults-transferfrom-is-not-transferring-locked-ether-otterse.sol";

contract Finding48700Test is Test {
    function test_exploit_seller_withdraws_locked_eth_after_transfer() public {
        Exploit e = new Exploit();
        uint256 beforeBal = e.token().balanceOf(address(e));
        e.run();
        assertEq(beforeBal, 1 ether, "capital");
        assertEq(e.token().balanceOf(address(e)), 2 ether, "price plus collateral");
        (uint256 tickets, uint256 locked) = e.vault().trader(address(e.buyer()));
        assertEq(tickets, 100, "buyer tickets");
        assertEq(locked, 0, "buyer locked");
        assertTrue(e.buyer().adjustReverted(), "adjust");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault");
    }

    function test_control_locked_eth_follows_the_tickets() public {
        ERC20 token = new ERC20();
        Vault vault = new Vault(token, true);
        Buyer buyer = new Buyer(token, vault);
        token.mint(address(this), 1 ether);
        token.mint(address(buyer), 1 ether);
        token.approve(address(vault), 1 ether);
        vault.purchase(1 ether);
        buyer.paySeller();
        vault.transferPosition(address(this), address(buyer));
        (, uint256 sellerLocked) = vault.trader(address(this));
        (, uint256 buyerLocked) = vault.trader(address(buyer));
        assertEq(sellerLocked, 0, "seller released");
        assertEq(buyerLocked, 1 ether, "buyer received lock");
        vault.withdraw();
        assertEq(token.balanceOf(address(this)), 1 ether, "seller keeps only the price");
        assertEq(token.balanceOf(address(vault)), 1 ether, "collateral stays");
    }
}
