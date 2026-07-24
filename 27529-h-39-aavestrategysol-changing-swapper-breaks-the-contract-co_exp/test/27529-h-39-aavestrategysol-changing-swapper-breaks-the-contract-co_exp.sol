// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./27529-h-39-aavestrategysol-changing-swapper-breaks-the-contract-co.sol";

contract AaveSwapperBreakTest is Test {
    function test_setMultiSwapper_bricks_compound() public {
        Exploit exp = new Exploit();
        exp.run();
        assertTrue(exp.compoundBroken(), "compound broken");
        assertEq(exp.rewardToken().balanceOf(address(exp.strategy())), exp.REWARDS());
    }

    function test_old_swapper_would_work() public {
        // Control: fresh strategy with initial swapper compounds fine.
        MockERC20 reward = new MockERC20("AAVE", "AAVE");
        MockERC20 weth = new MockERC20("WETH", "WETH");
        HonestSwapper swap = new HonestSwapper();
        AaveStrategy s = new AaveStrategy(reward, weth, address(swap));
        reward.mint(address(s), 50 ether);
        uint256 out = s.compound();
        assertEq(out, 50 ether);
        assertEq(weth.balanceOf(address(s)), 50 ether);
    }
}
