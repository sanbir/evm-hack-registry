// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, Supplier, LendingPoolFixed} from
    "./66504-h-03-incorrect-utilization-rate-in-deposit-and-withdraw-oper.sol";

contract Finding66504Test is Test {
    function test_exploit_stale_usage_refunds_160_ether() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.rate(), 0.2 ether, "util 20%");
        assertEq(e.interest(), 160 ether, "charged");
        assertEq(e.refunded(), 160 ether, "refund");
        assertEq(e.asset().balanceOf(address(e)), 160 ether, "borrower kept 160");
    }

    function test_control_accrued_debt_charges_the_full_320() public {
        Asset asset = new Asset();
        LendingPoolFixed pool = new LendingPoolFixed(asset, address(this));
        Supplier supplier = new Supplier();
        pool.seed(1000 ether, 800 ether, 320 ether);
        asset.mint(address(pool), 1320 ether);
        asset.mint(address(supplier), 1000 ether);
        supplier.approve(asset, address(pool));
        supplier.deposit(address(pool), 1000 ether);
        uint256 refund = pool.settle();

        assertEq(pool.currentUsageRate(), 0.4 ether, "util 40%");
        assertEq(refund, 0, "no refund");
        assertEq(asset.balanceOf(address(this)), 0, "borrower received nothing");
    }
}
