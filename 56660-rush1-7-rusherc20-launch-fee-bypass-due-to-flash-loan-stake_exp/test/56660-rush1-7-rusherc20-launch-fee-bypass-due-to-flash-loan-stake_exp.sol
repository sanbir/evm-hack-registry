// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, WETH, LiquidityPool, Pair, LiquidityDeployer} from
    "./56660-rush1-7-rusherc20-launch-fee-bypass-due-to-flash-loan-stake.sol";

contract Finding56660Test is Test {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant HONEST = 0x2222222222222222222222222222222222222222;

    function test_exploit_staker_takes_89_1_of_the_fee() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.weth().balanceOf(ATTACKER), 89.1 ether, "captured 89.1");
        assertEq(e.pool().lastWithdrawn(), 188.1 ether, "withdrew stake plus fee share");
    }

    function test_control_accounted_assets_keep_the_fee() public {
        WETH weth = new WETH();
        LiquidityPool pool = new LiquidityPool(weth, false);
        Pair pair = new Pair();
        LiquidityDeployer deployer = new LiquidityDeployer(weth, pool, pair, address(this));
        pool.seed(HONEST, 1 ether);
        weth.mint(address(this), 99 ether);
        weth.approve(address(pool), 99 ether);
        pool.deposit(99 ether);
        uint256 poolFee = deployer.deployLiquidity(1 ether, 1, 100 ether);
        assertEq(poolFee, 90 ether, "pool fee is 90");
        uint256 got = pool.withdraw(99 ether);
        assertEq(got, 99 ether, "stake comes back with none of the fee");
        assertEq(weth.balanceOf(address(pool)), 91 ether, "honest stake and the 90 fee stay");
    }
}
