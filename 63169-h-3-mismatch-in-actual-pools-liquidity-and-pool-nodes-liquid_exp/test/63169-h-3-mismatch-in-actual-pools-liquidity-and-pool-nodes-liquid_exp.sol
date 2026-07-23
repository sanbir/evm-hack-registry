// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./63169-h-3-mismatch-in-actual-pools-liquidity-and-pool-nodes-liquid.sol";

contract AmmplifyPoolNodeMismatchTest is Test {
    function test_exploit_wrongSettleRouteMismatchesLiquidity() public {
        Exploit e = new Exploit();
        e.run();

        assertTrue(e.rightWalker() != e.rightPoolWalker(), "off-by-one indices");
        assertEq(e.nodeLiqRight(), 1e18, "node has LIQ");
        assertEq(e.poolLiqRight(), 0, "pool missing position");
        assertTrue(e.furtherOpFailed(), "further ops fail");
    }
}
