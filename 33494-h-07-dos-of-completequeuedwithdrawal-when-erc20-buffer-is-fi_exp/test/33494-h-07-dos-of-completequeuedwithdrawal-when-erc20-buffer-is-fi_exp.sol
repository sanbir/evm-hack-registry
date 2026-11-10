// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    EzETH,
    WithdrawQueue,
    RestakeManager,
    DelegationManager,
    DepositQueue,
    OperatorDelegator,
    Withdrawal,
    IERC20
} from "./33494-h-07-dos-of-completequeuedwithdrawal-when-erc20-buffer-is-fi.sol";

contract DepositQueueFixed is DepositQueue {
    constructor(address _restakeManager, address _withdrawQueue, address _token)
        DepositQueue(_restakeManager, _withdrawQueue, _token)
    {}

    function fillERC20withdrawBuffer(address _asset, uint256 _amount) external override {
        require(_asset == address(token), "asset");
        token.transferFrom(msg.sender, address(withdrawQueue), _amount);
        withdrawQueue.creditBuffer(_amount);
    }
}

contract Finding33494Test is Test {
    uint256 internal constant N = 100e18;

    function test_exploit_buffer_fill_reverts_and_sticks_N() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.completionReverted(), "completeQueuedWithdrawal reverted");
        assertEq(e.stuckAmount(), N, "100 ezETH stuck in EigenLayer");
        assertEq(e.queuePaid(), 0, "withdraw queue was paid 0");
        assertEq(e.token().balanceOf(address(e.delegationManager())), N, "delegation manager still holds N");
        emit log_named_uint("stuck ezETH", e.stuckAmount());
        emit log_named_uint("queue paid", e.queuePaid());
    }

    function test_control_open_fill_completes_and_pays_N() public {
        EzETH token = new EzETH();
        WithdrawQueue withdrawQueue = new WithdrawQueue(address(token), N);
        RestakeManager restakeManager = new RestakeManager();
        DepositQueueFixed depositQueue =
            new DepositQueueFixed(address(restakeManager), address(withdrawQueue), address(token));
        restakeManager.setDepositQueue(address(depositQueue));
        DelegationManager delegationManager = new DelegationManager(address(token));
        OperatorDelegator delegator =
            new OperatorDelegator(address(this), address(restakeManager), address(delegationManager));

        token.mint(address(delegationManager), N);
        delegator.noteQueuedShares(address(token), N);

        Withdrawal memory withdrawal;
        withdrawal.strategies = new address[](1);
        withdrawal.shares = new uint256[](1);
        withdrawal.strategies[0] = address(token);
        withdrawal.shares[0] = N;

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = token;

        delegator.completeQueuedWithdrawal(withdrawal, tokens, 0);

        assertEq(token.balanceOf(address(withdrawQueue)), N, "control pays N to the withdraw queue");
        assertEq(token.balanceOf(address(delegationManager)), 0, "EigenLayer was emptied");
        assertEq(withdrawQueue.bufferFilled(), N, "small buffer was filled with N");
        emit log_named_uint("control paid", token.balanceOf(address(withdrawQueue)));
    }
}
