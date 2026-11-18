// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, MiniToken, MockSwap, UltiPumpFixed} from
    "./43913-h-02-dos-on-the-pump-function-due-to-excessively-low-slippag.sol";

contract Finding43913Test is Test {
    function test_exploit_99_bps_rejects_one_percent_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.pumpReverted(), "reverted");
        assertEq(e.inputLeft(), 1000 ether, "input");
        assertEq(e.ultiBought(), 0, "ulti");
        assertEq(e.minInternal(), 990.1 ether, "min");
    }

    function test_control_200_bps_covers_the_pool_fee() public {
        MiniToken inputToken = new MiniToken("WETH");
        MiniToken ulti = new MiniToken("ULTI");
        MockSwap router = new MockSwap();
        UltiPumpFixed pump = new UltiPumpFixed(inputToken, ulti, router);
        inputToken.mint(address(pump), 1000 ether);
        pump.approveRouter();
        uint256 out = pump.pump(1000 ether, 1);
        assertEq(out, 990 ether, "received after 1% fee");
        assertEq(ulti.balanceOf(address(pump)), 990 ether, "ulti balance");
        assertEq(inputToken.balanceOf(address(pump)), 0, "input spent");
    }
}
