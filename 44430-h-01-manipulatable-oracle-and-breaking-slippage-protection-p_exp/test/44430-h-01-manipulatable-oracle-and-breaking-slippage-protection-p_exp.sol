// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit} from "./44430-h-01-manipulatable-oracle-and-breaking-slippage-protection-p.sol";

contract Finding44430Test is Test {
    function test_sandwich_buys_dust_beam() public {
        Exploit e = new Exploit();
        e.run();
        emit log_named_uint("profit", e.profit());
        emit log_named_uint("protocolBeam", e.protocolBeam());
        assertEq(e.profit(), 99180327868852459007, "profit");
        assertLt(e.protocolBeam(), 1 ether, "dust beam");
    }
}
