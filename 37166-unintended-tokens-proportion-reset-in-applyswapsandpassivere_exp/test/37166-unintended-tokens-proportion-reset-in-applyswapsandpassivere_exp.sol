// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Token,
    Manager,
    Rebal,
    AFiBaseFixed
} from "./37166-unintended-tokens-proportion-reset-in-applyswapsandpassivere.sol";

contract Finding37166Test is Test {
    function test_exploit_strategy2_zeroes_proportions_and_dumps() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.proportion0(), 0, "proportion reset to 0");
        assertEq(e.received0(), 1000 ether, "counterparty received the dumped 1000");
        assertEq(e.token0().balanceOf(address(e.vault())), 0, "vault token0 is 0");
        assertEq(e.FAIR_HOLD() - e.token0().balanceOf(address(e.vault())), 1200 ether, "off by 1200");
    }

    function test_control_strategy2_keeps_6000_and_holds_1200() public {
        Token token0 = new Token();
        Token token1 = new Token();
        Rebal rebal = new Rebal(new Manager());
        AFiBaseFixed vault = new AFiBaseFixed(token0, token1, rebal);
        token0.mint(address(vault), 1000 ether);
        token1.mint(address(vault), 1000 ether);
        token0.mint(address(this), 1000 ether);
        token0.approve(address(vault), 1000 ether);

        uint256 proportion0 = vault.applySwapsAndPassiveRebal();
        vault.swapToward(address(this));

        assertEq(proportion0, 6000, "6000 bps kept");
        assertEq(token0.balanceOf(address(vault)), 1200 ether, "vault holds 1200 token0");
        assertEq(token0.balanceOf(address(this)), 800 ether, "counterparty sold 200 token0");
    }
}
