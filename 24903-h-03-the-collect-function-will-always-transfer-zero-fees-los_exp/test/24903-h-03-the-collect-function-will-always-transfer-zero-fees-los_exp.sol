// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./24903-h-03-the-collect-function-will-always-transfer-zero-fees-los.sol";

contract CollectZeroFeesTest is Test {
    function test_collect_transfers_zero_and_burns_fees() public {
        Exploit exp = new Exploit();
        MockPool pool = exp.pool();
        TimeswapV2LiquidityToken lt = exp.lt();

        exp.run();

        // HARM: recipient received zero of each fee token.
        assertEq(pool.long0Bal(exp.RECIPIENT()), 0, "long0 transfer must be zero");
        assertEq(pool.long1Bal(exp.RECIPIENT()), 0, "long1 transfer must be zero");
        assertEq(pool.shortBal(exp.RECIPIENT()), 0, "short transfer must be zero");

        // HARM: fee position fully burned despite zero payout.
        (uint256 b0, uint256 b1, uint256 bs) = lt.getFeesOf(address(exp));
        assertEq(b0, 0, "long0 fees burned");
        assertEq(b1, 0, "long1 fees burned");
        assertEq(bs, 0, "short fees burned");
        assertTrue(lt.burned(address(exp)), "burn flag");
    }
}
