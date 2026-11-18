// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, RaacToken, RewardsReceiver, RAACMinter} from
    "./66354-h-13-permanent-loss-of-rewards-when-distribution-fails-pasho.sol";

contract Finding66354Test is Test {
    function test_exploit_pool_a_loses_400_rewards() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.poolA().received(), 0, "A received nothing");
        assertEq(e.poolB().received(), 600, "B received its weight");
        assertEq(e.stuck(), 400, "400 locked in the minter");
        assertEq(e.token().balanceOf(address(e.minter())), 400, "balance stuck");
        assertEq(e.minter().excessTokens(), 0, "excess already cleared");
        assertEq(e.minter().pendingOf(address(e.poolA())), 0, "memory pending discarded");
    }

    function test_control_storage_pending_can_be_retried() public {
        RaacToken token = new RaacToken();
        RewardsReceiver poolA = new RewardsReceiver(token, true);
        RewardsReceiver poolB = new RewardsReceiver(token, false);
        RAACMinter minter = new RAACMinter(token, address(poolA), 2, address(poolB), 3, true);
        token.mint(address(minter), 1000);
        minter.fundExcess(1000);
        minter.process();

        assertEq(poolB.received(), 600, "B still paid");
        assertEq(minter.pendingOf(address(poolA)), 400, "A pending kept in storage");
        assertEq(minter.excessTokens(), 0, "excess still cleared");
        assertEq(token.balanceOf(address(minter)), 400, "tokens wait on the recorded pending");

        poolA.setFail(false);
        minter.flush(address(poolA));
        assertEq(poolA.received(), 400, "retry pays A");
        assertEq(token.balanceOf(address(minter)), 0, "minter empty");
        assertEq(minter.pendingOf(address(poolA)), 0, "pending cleared after success");
    }
}
