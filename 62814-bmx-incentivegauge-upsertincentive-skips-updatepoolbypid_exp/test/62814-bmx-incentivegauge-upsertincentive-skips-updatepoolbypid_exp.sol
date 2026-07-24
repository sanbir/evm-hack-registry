// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./62814-bmx-incentivegauge-upsertincentive-skips-updatepoolbypid.sol";

contract Finding62814Test is Test {
    function testFinding62814() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("before", e.beforeValue());
        emit log_named_uint("after", e.afterValue());
        emit log_named_uint("delta", e.profit());
        assertTrue(e.stateDiverged());
        assertGt(e.profit(), 0);
        
    }
}
