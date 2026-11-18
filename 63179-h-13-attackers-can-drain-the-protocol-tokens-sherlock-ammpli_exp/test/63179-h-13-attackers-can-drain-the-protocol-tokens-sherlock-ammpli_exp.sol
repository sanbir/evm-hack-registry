// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit} from "./63179-h-13-attackers-can-drain-the-protocol-tokens-sherlock-ammpli.sol";

contract Finding63179Test is Test {
    function test_exploit_fake_pool_drains_both_tokens() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token0().balanceOf(address(this)), 1_000_000 ether, "token0");
        assertEq(e.token1().balanceOf(address(this)), 250_000 ether, "token1");
        assertEq(e.token0().balanceOf(address(e.maker())), 0, "maker0");
        assertEq(e.token1().balanceOf(address(e.maker())), 0, "maker1");
    }
}
