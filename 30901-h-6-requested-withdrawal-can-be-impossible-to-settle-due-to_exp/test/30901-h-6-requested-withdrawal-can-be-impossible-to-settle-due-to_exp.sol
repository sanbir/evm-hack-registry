// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30901-h-6-requested-withdrawal-can-be-impossible-to-settle-due-to.sol";

contract WithdrawalStuckOnAppreciationTest is Test {
    Exploit internal exploit;

    function setUp() public {
        exploit = new Exploit();
    }

    function test_exploit() public {
        exploit.run();

        Coordinator coord = exploit.coordinator();
        DepositPool pool = exploit.depositPool();

        // Re-assert the harm from outside run(): Bob's withdrawal never
        // settled, even though the pool still holds his full 100e18 of value.
        assertEq(coord.sharesOwedCurrentEpoch(), 100e18, "withdrawal should remain stuck");
        assertEq(pool.poolBalance(), 100e18, "pool balance should be untouched by the failed settlement");

        vm.expectRevert(Coordinator.INCORRECT_NUMBER_OF_SHARES_QUEUED.selector);
        coord.rebalance();
    }

    /// @notice Control: WITHOUT the rate appreciating between request and
    ///         settlement, the same withdrawal settles cleanly.
    function test_control_noAppreciationSettlesCleanly() public {
        Strategy strategy = new Strategy();
        AssetRegistry assetRegistry = new AssetRegistry(address(strategy));
        DepositPool pool = new DepositPool(address(assetRegistry));
        OperatorRegistry operatorRegistry = new OperatorRegistry();
        Coordinator coord = new Coordinator(address(assetRegistry), address(pool), address(operatorRegistry));

        uint256 aliceShares = strategy.deposit(5e18);
        operatorRegistry.allocate(aliceShares);

        pool.receiveDeposit(100e18);
        coord.requestWithdrawal(100e18);

        // No donation this time — the rate stays 1:1, so the pool alone
        // fully covers the withdrawal.
        coord.rebalance();

        assertEq(coord.sharesOwedCurrentEpoch(), 0, "withdrawal should settle cleanly without rate appreciation");
    }
}
