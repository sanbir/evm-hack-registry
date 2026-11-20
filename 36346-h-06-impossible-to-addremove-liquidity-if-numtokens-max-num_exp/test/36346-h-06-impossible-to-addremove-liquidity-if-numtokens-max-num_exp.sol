// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, PoolFixed} from
    "./36346-h-06-impossible-to-addremove-liquidity-if-numtokens-max-num.sol";

contract Finding36346Test is Test {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    function test_exploit_fixed_array_pays_nothing() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.pool().lpOf(address(e)), 200 ether, "lp remains");
        assertEq(e.pool().liquidity(), 200 ether, "reserves remain");
        assertEq(e.marker().balanceOf(SINK), 200 ether, "200 locked");
    }

    function test_control_dynamic_array_pays_200() public {
        PoolFixed pool = new PoolFixed();
        pool.seed(address(this), 200 ether);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100 ether;
        amounts[1] = 100 ether;
        uint256 out = pool.removeLiquidity(amounts, address(this));
        assertEq(out, 200 ether, "lp paid");
        assertEq(pool.lpOf(address(this)), 0, "lp cleared");
        assertEq(pool.liquidity(), 0, "reserves paid");
    }
}
