// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit} from "./52787-h-01-incorrect-assumptions-about-chain-native-token-will-hea.sol";

contract Finding52787Test is Test {
    function test_eth_priced_warn_sticks_the_ante() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 1 ether);
        e.run{value: 0.02 ether}();
        assertEq(e.debtTaken(), 2371e16, "booked at the ETH price");
        assertEq(e.anteStuck(), 0.01 ether, "0.01 native stuck");
        assertTrue(e.warnReverted(), "ETH-priced swap reverted");
        assertEq(e.controlOut(), 629e14, "native-priced swap pays 0.0629");
        emit log_named_uint("debt booked", e.debtTaken());
        emit log_named_uint("ante stuck", e.anteStuck());
        emit log_named_uint("control out", e.controlOut());
    }
}
