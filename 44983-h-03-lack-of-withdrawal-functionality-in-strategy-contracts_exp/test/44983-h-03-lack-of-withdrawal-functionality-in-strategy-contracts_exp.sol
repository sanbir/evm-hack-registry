// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "forge-std/Test.sol";
import {Exploit, Token, LidoStrategyFixed, DepositETH} from "./44983-h-03-lack-of-withdrawal-functionality-in-strategy-contracts.sol";
contract Finding44983Test is Test {
    function test_exploit_steth_stuck() public {
        Exploit e = new Exploit();
        e.run();
        assertTrue(e.redeemReverted(), "redeem reverted");
        assertEq(e.steth().balanceOf(address(e.vault())), 10 ether, "10 stETH stuck");
        assertEq(e.ethToken().balanceOf(address(e)), 0, "no ETH back");
    }
    function test_control_fixed_strategy_returns_eth() public {
        Token eth = new Token("ETH");
        Token st = new Token("stETH");
        LidoStrategyFixed fixedS = new LidoStrategyFixed();
        DepositETH vault = new DepositETH(address(this), eth, st, address(fixedS));
        eth.mint(address(this), 10 ether);
        eth.approve(address(vault), 10 ether);
        vault.deposit(10 ether);
        DepositETH.StrategyExecution[] memory stake = new DepositETH.StrategyExecution[](1);
        stake[0] = DepositETH.StrategyExecution(address(fixedS), abi.encodeWithSignature("stake(address,address)", address(eth), address(st)));
        vault.executeStrategies(stake);
        assertEq(st.balanceOf(address(vault)), 10 ether, "staked");
        DepositETH.StrategyExecution[] memory wd = new DepositETH.StrategyExecution[](1);
        wd[0] = DepositETH.StrategyExecution(address(fixedS), abi.encodeWithSignature("withdraw(address,address,uint256)", address(eth), address(st), 10 ether));
        vault.executeStrategies(wd);
        assertEq(eth.balanceOf(address(vault)), 10 ether, "unwrapped");
        assertEq(st.balanceOf(address(vault)), 0, "stETH gone");
    }
}
