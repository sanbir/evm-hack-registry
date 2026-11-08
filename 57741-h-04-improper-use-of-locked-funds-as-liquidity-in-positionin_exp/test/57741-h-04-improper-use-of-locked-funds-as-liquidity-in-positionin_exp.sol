// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset} from "./57741-h-04-improper-use-of-locked-funds-as-liquidity-in-positionin.sol";

/// @dev Control: a call payout may spend only buyToken that is not locked for a put.
contract PoolSafe {
    Asset public token;
    address public locker;
    uint256 public lockedBuy;

    constructor(Asset _token) {
        token = _token;
    }

    function depositPut(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        locker = msg.sender;
        lockedBuy = lockedBuy + amount;
    }

    function exerciseCall(uint256 pnl) external returns (uint256 paid) {
        uint256 bal = token.balanceOf(address(this));
        uint256 freeBal = bal - lockedBuy;
        if (pnl > freeBal) pnl = freeBal;
        if (pnl == 0) return 0;
        token.transfer(msg.sender, pnl);
        return pnl;
    }

    function withdrawLocked() external returns (uint256 out) {
        if (msg.sender != locker) return 0;
        out = lockedBuy;
        lockedBuy = 0;
        token.transfer(msg.sender, out);
    }
}

contract Finding57741Test is Test {
    function test_exploit_pulls_locked_funds_into_the_call() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.lockedBefore(), 1000 ether, "locked");
        assertEq(e.paidToCall(), 1000 ether, "pulled into the call");
        assertEq(e.lockerGot(), 0, "locker got nothing");
        assertEq(e.poolLeft(), 0, "pool empty");
        assertEq(e.token().balanceOf(address(e)), 1000 ether, "call holder holds the lock");
        assertEq(e.pool().lockedBuy(), 1000 ether, "lock accounting still 1000");
    }

    function test_control_locker_can_withdraw() public {
        Asset token = new Asset();
        PoolSafe pool = new PoolSafe(token);
        token.mint(address(this), 1000 ether);
        token.approve(address(pool), 1000 ether);
        pool.depositPut(1000 ether);
        uint256 paid = pool.exerciseCall(1000 ether);
        uint256 got = pool.withdrawLocked();
        assertEq(paid, 0, "call cannot spend the lock");
        assertEq(got, 1000 ether, "locker withdrew 1000");
        assertEq(token.balanceOf(address(this)), 1000 ether, "locker holds 1000");
        assertEq(token.balanceOf(address(pool)), 0, "pool empty after a real withdraw");
    }
}
