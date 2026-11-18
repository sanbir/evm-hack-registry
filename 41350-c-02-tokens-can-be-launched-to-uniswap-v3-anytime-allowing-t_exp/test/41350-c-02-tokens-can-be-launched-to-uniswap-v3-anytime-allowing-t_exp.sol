// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Eth, GroupcoinFactory} from
    "./41350-c-02-tokens-can-be-launched-to-uniswap-v3-anytime-allowing-t.sol";

contract Finding41350Test is Test {
    function test_exploit_launch_without_enable_takes_2_eth() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.factory().commitLaunch(e.tokenId()), 0, "enable was never called");
        assertEq(e.factory().drained(), 2 ether, "2 ETH taken");
        assertEq(e.eth().balanceOf(address(e)), 2 ether, "attacker received it");
        assertEq(e.eth().balanceOf(address(e.factory())), 0, "factory empty");
    }

    function test_control_enabled_launch_reverts_in_the_same_block() public {
        Eth eth = new Eth();
        GroupcoinFactory factory = new GroupcoinFactory(eth);
        eth.mint(address(factory), 2 ether);
        uint256 tokenId = factory.launchGroupCoin();
        factory.enableUniswapV3Launch(tokenId);
        vm.expectRevert(GroupcoinFactory.CantLaunchPoolYet.selector);
        factory.launchGroupCoinToUniswapV3(tokenId);
        assertEq(eth.balanceOf(address(factory)), 2 ether, "liquidity stays");
    }
}
