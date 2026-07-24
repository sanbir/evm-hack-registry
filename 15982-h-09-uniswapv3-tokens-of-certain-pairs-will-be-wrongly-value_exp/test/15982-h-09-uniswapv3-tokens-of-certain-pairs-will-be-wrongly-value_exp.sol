// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./15982-h-09-uniswapv3-tokens-of-certain-pairs-will-be-wrongly-value.sol";

contract PoC_15982 is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();
    }
}
