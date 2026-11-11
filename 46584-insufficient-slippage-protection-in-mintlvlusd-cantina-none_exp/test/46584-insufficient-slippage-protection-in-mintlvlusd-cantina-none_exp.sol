// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    LevelMinting,
    LevelBaseReserveManagerFixed
} from "./46584-insufficient-slippage-protection-in-mintlvlusd-cantina-none.sol";

contract Finding46584Test is Test {
    function test_exploit_minter_receives_less_than_stated_minimum() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.manager().minOutPassed(), 0.5 ether, "minOut passed to mint is 0.5");
        assertEq(e.received(), 0.5 ether, "received 0.5 lvlUSD");
        assertEq(e.statedMin(), 999.5 ether, "stated minimum is 999.5");
        assertLt(e.received(), e.statedMin(), "received is below the stated minimum");
        assertEq(e.lvl().balanceOf(address(e)), 0.5 ether, "exploit holds the dust fill");
        assertEq(e.collateral().balanceOf(address(e)), 0, "1000 collateral taken");
        assertEq(e.collateral().balanceOf(address(e.minting())), 1000 ether, "minter kept the collateral");
    }

    function test_control_minOut_reverts_the_dust_fill() public {
        MockToken collateral = new MockToken("USD Coin", "USDC");
        MockToken lvl = new MockToken("Level USD", "lvlUSD");
        LevelMinting minting = new LevelMinting(lvl);
        LevelBaseReserveManagerFixed manager = new LevelBaseReserveManagerFixed(minting);

        collateral.mint(address(this), 1000 ether);
        collateral.approve(address(manager), 1000 ether);

        vm.expectRevert(bytes("minOut"));
        manager.mintlvlUSD(address(collateral), 1000 ether);

        assertEq(collateral.balanceOf(address(this)), 1000 ether, "collateral not taken");
        assertEq(lvl.balanceOf(address(this)), 0, "no dust lvlUSD minted");
    }
}
