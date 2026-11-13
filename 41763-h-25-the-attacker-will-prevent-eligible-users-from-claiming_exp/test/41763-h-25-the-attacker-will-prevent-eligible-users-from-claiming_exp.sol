// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Eth,
    CollectionToken,
    Locker,
    CollectionShutdownFixed
} from "./41763-h-25-the-attacker-will-prevent-eligible-users-from-claiming.sol";

contract Finding41763Test is Test {
    function test_exploit_cancel_locks_lewis_sale_proceeds() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.held(), 2 ether, "2 ETH stuck");
        assertEq(e.lewisClaim(), 0, "lewis claim wiped");
        assertEq(e.eth().balanceOf(address(e.shutdown())), 2 ether, "shutdown holds 2");
        assertTrue(e.canExecuteAfterVote(), "vote reopened execution");
        assertEq(e.denomAfter(), 0, "denomination rewritten");
    }

    function test_control_executed_shutdown_cannot_be_revoted() public {
        Eth eth = new Eth();
        CollectionToken ct = new CollectionToken(4);
        Locker locker = new Locker(ct);
        address lewis = address(0x1E715);
        address nft = address(0x721);
        CollectionShutdownFixed shutdown = new CollectionShutdownFixed(locker, eth, lewis);
        uint256 votes = 2e18 * 10 ** 4;
        ct.mint(lewis, votes);
        ct.mint(address(this), 1);
        ct.mint(address(0xBEEF), votes - 1);
        shutdown.seed(nft, ct, uint96(votes));
        eth.mint(address(this), 2 ether);
        eth.approve(address(shutdown), 2 ether);
        shutdown.creditProceeds(nft, 2 ether);
        ct.approve(address(shutdown), 1);

        bool reverted;
        try shutdown.vote(nft) {
            reverted = false;
        } catch {
            reverted = true;
        }

        assertTrue(reverted, "vote after execution reverts");
        assertEq(shutdown.claimable(nft, lewis), 2 ether, "lewis can still claim");
        assertEq(ct.denomination(), 4, "denomination unchanged");
    }
}
