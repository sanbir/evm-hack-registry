// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, Asset, Pool} from "./57735-c-01-permanent-lock-due-to-missing-unlock-mechanism-for-opti.sol";

/// @dev The control adds the unlock the vulnerable pool does not have.
contract PoolWithUnlock {
    Asset public token;
    uint256 public lockedToken;
    address public depositor;

    constructor(Asset _token) {
        token = _token;
    }

    function openCall(uint256 sizeUa) external {
        token.transferFrom(msg.sender, address(this), sizeUa);
        depositor = msg.sender;
        lockedToken = lockedToken + sizeUa;
    }

    function exerciseOrLiquidate(uint256 payoff) external returns (uint256) {
        if (payoff == 0) return 0;
        return 0;
    }

    function unlockWorthless() external {
        uint256 amount = lockedToken;
        lockedToken = 0;
        token.transfer(depositor, amount);
    }
}

contract Finding57735Test is Test {
    function test_exploit_locks_tokens_with_no_withdraw() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.locked(), 1000 ether, "locked");
        assertEq(e.exercisable(), false, "not exercisable");
        assertEq(e.released(), 0, "no release");
        assertEq(e.stuck(), 1000 ether, "stuck in the pool");
        assertEq(e.token().balanceOf(address(e)), 0, "depositor empty");
        assertEq(e.pool().isPayoffAvailable(0), false, "payoff 0");
    }

    function test_control_unlock_returns_the_tokens() public {
        Asset token = new Asset();
        PoolWithUnlock pool = new PoolWithUnlock(token);
        token.mint(address(this), 1000 ether);
        token.approve(address(pool), 1000 ether);
        pool.openCall(1000 ether);
        assertEq(pool.exerciseOrLiquidate(0), 0, "exercise still pays nothing");
        assertEq(token.balanceOf(address(pool)), 1000 ether, "still locked");
        pool.unlockWorthless();
        assertEq(pool.lockedToken(), 0, "unlocked");
        assertEq(token.balanceOf(address(this)), 1000 ether, "depositor received 1000");
        assertEq(token.balanceOf(address(pool)), 0, "pool empty");
    }
}
