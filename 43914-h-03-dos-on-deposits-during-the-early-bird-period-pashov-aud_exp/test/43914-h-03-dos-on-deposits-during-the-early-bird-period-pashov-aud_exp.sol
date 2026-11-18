// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Erc20, Pool, UltiFixed} from
    "./43914-h-03-dos-on-deposits-during-the-early-bird-period-pashov-aud.sol";

contract Finding43914Test is Test {
    function test_exploit_early_bird_deposit_reverts_after_swap() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.depositReverted(), "deposit dos");
        assertEq(e.ultiOut(), 2 * 10 ** 35, "swap bought 2e35");
        assertEq(e.ulti().balanceOf(address(e)), 2 * 10 ** 35, "attacker holds the ulti");
        assertEq(e.inputToken().balanceOf(address(e)), 10 ether, "deposit not taken");
    }

    function test_control_spot_price_deposit_succeeds_after_swap() public {
        Erc20 input = new Erc20("WETH");
        Erc20 ulti = new Erc20("ULTI");
        uint256 x = 1000 ether;
        uint256 y = 1000 ether * 1e15;
        Pool pool = new Pool(input, ulti, x, y);
        input.mint(address(pool), x);
        ulti.mint(address(pool), y);
        UltiFixed market = new UltiFixed(input, ulti, pool);
        input.mint(address(this), 260 ether);
        input.approve(address(pool), 250 ether);
        pool.swapInputForUlti(250 ether);
        uint256 price = 1e18 * pool.inputReserve() / pool.ultiReserve();
        uint256 ultiForLP = (5 ether) * 1e18 / price;
        ulti.mint(address(this), ultiForLP);
        input.approve(address(market), 10 ether);
        ulti.approve(address(market), ultiForLP);
        market.deposit(10 ether);
        assertGt(pool.inputReserve(), 1250 ether, "liquidity was added");
        assertEq(input.balanceOf(address(this)), 5 ether, "non-lp input remains with the user");
    }
}
