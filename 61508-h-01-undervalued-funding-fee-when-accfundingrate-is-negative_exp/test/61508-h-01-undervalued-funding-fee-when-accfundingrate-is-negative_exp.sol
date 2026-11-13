// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    FundingFixed,
    Token
} from "./61508-h-01-undervalued-funding-fee-when-accfundingrate-is-negative.sol";

contract Finding61508Test is Test {
    function test_exploit_longs_receive_100000_instead_of_400000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.longGot(), 100000 ether, "long credit");
        assertEq(e.shortKept(), 300000 ether, "short refund");
        assertEq(e.usdc().balanceOf(address(e.funding())), 0);
    }

    function test_control_negative_rate_pays_longs_400000() public {
        Token usdc = new Token("USDC", "USDC", 18);
        FundingFixed funding = new FundingFixed(usdc);
        address longTrader = address(0x4444);
        funding.init(longTrader, address(this), 100 ether, 400 ether);
        usdc.mint(address(funding), 400000 ether);
        uint256 longCredit = funding.settle(-1000 ether);
        assertEq(longCredit, 400000 ether, "full funding");
        assertEq(usdc.balanceOf(longTrader), 400000 ether);
        assertEq(usdc.balanceOf(address(this)), 0, "short was refunded");
        assertEq(usdc.balanceOf(address(funding)), 0);
    }
}
