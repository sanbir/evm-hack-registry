// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./64079-h-1-attacker-can-profit-by-manipulating-uniswap-liquidity-sh.sol";

contract StNxmSlot0ManipTest is Test {
    function test_exploit() public {
        Exploit e = new Exploit();
        e.run();

        assertGt(e.actualPayout(), e.fairPayout(), "inflated payout");
    }
}
