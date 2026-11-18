// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;
import "forge-std/Test.sol";
import {Exploit, SwapToken, ConstantProductPool, LiquidationSwap} from "./66505-h-04-liquidationswap-at-risk-of-sandwich-attacks-due-to-spot.sol";

contract Finding66505Test is Test {
    function test_exploit_sandwich_extracts_600_index() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.liq().crvOut(), 250 ether, "stability out");
        assertEq(e.index().balanceOf(address(e)), 1600 ether, "attacker index");
        assertEq(e.index().balanceOf(address(e)) - 1000 ether, 600 ether, "profit");
    }

    function test_control_pretrade_floor_reverts_the_sandwich() public {
        SwapToken crv = new SwapToken("crvUSD");
        SwapToken index = new SwapToken("IDX");
        ConstantProductPool pool = new ConstantProductPool(crv, index);
        LiquidationSwap liq = new LiquidationSwap(pool, index);
        index.mint(address(pool), 2000 ether);
        crv.mint(address(pool), 1500 ether);
        pool.sync();
        index.mint(address(this), 1000 ether);
        index.mint(address(liq), 1000 ether);
        index.approve(address(pool), type(uint256).max);
        uint256 fair = pool.get_dy(1, 0, 1000 ether);
        assertEq(fair, 500 ether, "fair");
        pool.exchange(1, 0, 1000 ether, 0);
        vm.expectRevert(bytes("slippage"));
        liq.liquidateWithFloor(fair);
        assertEq(index.balanceOf(address(liq)), 1000 ether, "index unsold");
    }
}
