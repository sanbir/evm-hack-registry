// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, VeFixed} from "./66160-c-06-stale-total-voting-power-snapshot-leads-to-incorrect-re.sol";

contract Locker66160 {
    function lock(VeFixed ve, ERC20Mini raac, uint256 amt) external {
        raac.approve(address(ve), amt);
        ve.lock(amt, 365 days);
    }

    function claim(VeFixed ve, address usdt) external {
        ve.claim(usdt);
    }
}

contract FindingRewardTest is Test {
    function test_exploit_stale_snapshot_overpays_bob_and_bricks_alice() public {
        Exploit e = new Exploit();
        e.setupPositions();
        vm.warp(block.timestamp + 7 days);
        e.run();
        assertGt(e.owed(), 100_000_000, "owed");
        assertEq(e.bobPayout(), 99_999_900, "bob");
        assertTrue(e.aliceClaimReverted(), "alice");
        assertEq(e.usdt().balanceOf(address(e.alice())), 0, "alice bal");
        assertEq(e.usdt().balanceOf(address(e.ve())), 100, "dust left");
    }

    function test_control_current_supply_pays_both() public {
        ERC20Mini raac = new ERC20Mini();
        ERC20Mini usdt = new ERC20Mini();
        VeFixed ve = new VeFixed(raac);
        Locker66160 bob = new Locker66160();
        Locker66160 alice = new Locker66160();
        raac.mint(address(bob), 100 ether);
        raac.mint(address(alice), 100 ether);
        usdt.mint(address(this), 100_000_000);
        bob.lock(ve, raac, 100 ether);
        usdt.approve(address(ve), 100_000_000);
        ve.notifyRewardAmount(address(usdt), 100_000_000);
        alice.lock(ve, raac, 100 ether);
        vm.warp(block.timestamp + 7 days);
        assertEq(ve.earned(address(bob)), 49_999_900, "bob half");
        assertEq(ve.earned(address(alice)), 49_999_900, "alice half");
        bob.claim(ve, address(usdt));
        alice.claim(ve, address(usdt));
        assertEq(usdt.balanceOf(address(bob)), 49_999_900, "bob paid");
        assertEq(usdt.balanceOf(address(alice)), 49_999_900, "alice paid");
    }
}
