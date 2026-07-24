// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import "./64014-h-01-removed-strategy-bypass-removal-block-withdrawals.sol";

contract PoC_64014 is Test {
    function test_removed_strategy_still_called_after_registry_delete() public {
        Exploit exploit = new Exploit();
        exploit.run();
        assertEq(exploit.withdrawnAfterRemoval(), 100);
        (StrategyKind kind, bool active) = exploit.registry().strategies(address(exploit.strategy()));
        assertEq(uint256(kind), 0);
        assertFalse(active);
    }
}
