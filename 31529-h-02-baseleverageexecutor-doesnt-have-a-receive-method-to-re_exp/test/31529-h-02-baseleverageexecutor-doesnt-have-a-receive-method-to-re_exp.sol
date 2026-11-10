// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    BaseLeverageExecutorFixed,
    EthTOFT,
    Exploit,
    WETH9
} from "./31529-h-02-baseleverageexecutor-doesnt-have-a-receive-method-to-re.sol";

contract Finding31529Test is Test {
    uint256 internal constant AMOUNT = 1 ether;

    receive() external payable {}

    function test_exploit_eth_stuck_in_weth() public {
        Exploit e = new Exploit();
        e.run{value: AMOUNT}();

        assertEq(e.AMOUNT(), AMOUNT, "amount");
        assertTrue(e.unwrapReverted(), "unwrap reverted");
        assertEq(e.stuckInWeth(), AMOUNT, "1 ETH seated in WETH");
        assertEq(e.userReceived(), 0, "user received nothing");
        assertEq(address(e.weth()).balance, AMOUNT, "1 ETH stuck in WETH");
        assertEq(e.weth().balanceOf(address(e.executor())), AMOUNT, "executor still holds 1 WETH");
    }

    function test_control_receive_pays_the_user() public {
        WETH9 weth = new WETH9();
        EthTOFT toft = new EthTOFT();
        BaseLeverageExecutorFixed executor = new BaseLeverageExecutorFixed(weth);

        uint256 start = address(this).balance;
        executor.fund{value: AMOUNT}();
        assertEq(address(weth).balance, AMOUNT, "funded");
        assertEq(address(this).balance, start - AMOUNT, "user paid in");

        uint256 before = address(this).balance;
        executor.getAsset(address(toft), AMOUNT);

        assertEq(address(this).balance, before + AMOUNT, "user gets 1 ETH");
        assertEq(address(this).balance, start, "full 1 ETH returned");
        assertEq(address(weth).balance, 0, "WETH empty");
        assertEq(weth.balanceOf(address(executor)), 0, "executor WETH burned");
        assertEq(address(executor).balance, 0, "executor kept no ETH");
    }
}
