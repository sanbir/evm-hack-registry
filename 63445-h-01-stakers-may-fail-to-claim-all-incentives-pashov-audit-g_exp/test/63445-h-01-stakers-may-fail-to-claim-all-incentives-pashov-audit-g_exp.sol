// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {Exploit, UniswapV3Staker, MockPositionNFT, MarkerToken} from "./63445-h-01-stakers-may-fail-to-claim-all-incentives-pashov-audit-g.sol";

// Ouroboros H-01 (finding 63445): the Uniswap-v3-staker fork guards BOTH exit
// paths (`decreaseLiquidity` and `withdrawToken`) with the verbatim
// `require(!... .buildsPOL, 'E024')`. Nothing ever clears `buildsPOL`, so a
// position that joined a POL-building incentive is permanently locked in the
// staker: the staker can never decrease liquidity nor withdraw their NFT.
contract Finding63445Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_POLPositionPermanentlyLocked() public {
        Exploit e = new Exploit();
        e.run();

        emit log_named_uint("locked position value", e.lockedValue());
        emit log_named_uint("sink marker balance", MarkerToken(e.marker()).balanceOf(SINK));

        assertTrue(e.controlWithdrawSucceeded(), "control non-POL position must withdraw fine");
        assertTrue(e.decreaseReverted(), "decreaseLiquidity must revert E024 for POL position");
        assertTrue(e.withdrawReverted(), "withdrawToken must revert E024 for POL position");
        assertTrue(e.stuck(), "position NFT must remain stuck in the staker");
        assertEq(e.lockedValue(), 1000 ether, "locked liquidity value is 1000e18");
        assertEq(MarkerToken(e.marker()).balanceOf(SINK), 1000 ether, "stuck value registered at sink");
    }
}
