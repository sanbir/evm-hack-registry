// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./62647-chat-points-manipulation-by-adding-liquidity-to-custom-pools.sol";

contract ChatPointsTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
