// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";

import {Exploit, GammaVault, MockToken, Router} from "./45530-h-01-incorrect-swapping-path-in-processwithdrawals-pashov-au.sol";
contract Finding45530Test is Test {
    function test_wrong_path_delivers_zero_weth() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.received(), 0);
        assertEq(e.routerWeth(), 300e18);
        assertEq(e.usdc().balanceOf(address(e.vault())), 200e18);
    }
    function test_control_path0_delivers_200_weth() public {
        MockToken usdc = new MockToken("USDC");
        MockToken weth = new MockToken("WETH");
        Router router = new Router();
        address sink = address(0xD00D);
        GammaVault vault = new GammaVault(usdc, weth, router, sink);
        usdc.mint(address(vault), 100e18);
        weth.mint(address(vault), 100e18);
        usdc.mint(address(router), 200e18);
        weth.mint(address(router), 200e18);
        vault.processWithdrawals(abi.encode(address(usdc), address(weth)), abi.encode(address(usdc), address(weth)));
        assertEq(weth.balanceOf(sink), 200e18);
    }
}
