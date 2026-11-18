// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BondToken, Erc20, Distributor, PoolFixed} from
    "./49235-h-6-malicious-user-can-leverage-flash-loans-to-claim-all-cou.sol";

contract Finding49235Test is Test {
    function test_exploit_flash_mint_takes_every_coupon() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.attackerCoupons(), 1000 ether, "attacker took 1000");
        assertEq(e.victimCoupons(), 0, "holder got 0");
        assertEq(e.coupon().balanceOf(address(e)), 1000 ether, "balance");
        assertEq(e.bond().balanceOf(address(e)), 0, "flash repaid");
    }

    function test_control_snapshot_pays_the_existing_holder() public {
        BondToken bond = new BondToken();
        Erc20 coupon = new Erc20("COUPON");
        Distributor dist = new Distributor(coupon, bond);
        PoolFixed pool = new PoolFixed(bond, coupon, dist, 1 ether, 1000 ether);
        address victim = address(0xBEEF);
        address attacker = address(0xA11CE);
        bond.mint(victim, 100 ether);
        pool.snapshot(victim);
        pool.snapshot(attacker);
        bond.mint(attacker, 1000 ether);
        pool.startAuction();
        coupon.mint(address(pool), 1000 ether);
        uint256 victimPaid = pool.claimFromSnapshot(victim);
        uint256 attackerPaid = pool.claimFromSnapshot(attacker);
        assertEq(victimPaid, 100 ether, "holder paid for 100 bonds");
        assertEq(attackerPaid, 0, "flash mint is not in the snapshot");
        assertEq(coupon.balanceOf(victim), 100 ether, "victim received coupons");
        assertEq(coupon.balanceOf(attacker), 0, "attacker received none");
    }
}
