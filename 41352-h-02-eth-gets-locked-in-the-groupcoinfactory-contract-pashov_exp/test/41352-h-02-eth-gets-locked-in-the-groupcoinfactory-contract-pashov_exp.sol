// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, WETH9, GroupcoinFactoryFixed} from
    "./41352-h-02-eth-gets-locked-in-the-groupcoinfactory-contract-pashov.sol";

contract Finding41352Test is Test {
    function test_exploit_leaves_1616692000000000_wei_locked() public {
        Exploit e = new Exploit();
        vm.deal(address(this), e.PAID());
        e.run{value: e.PAID()}();

        assertEq(address(e.factory()).balance, e.LOCKED(), "factory dust");
        assertEq(e.weth().balanceOf(address(e.factory())), e.TOKEN1(), "wrapped only token1");
        assertEq(e.factoryEth(), e.LOCKED(), "recorded");
    }

    function test_control_wrapping_the_full_balance_leaves_nothing() public {
        WETH9 weth = new WETH9();
        GroupcoinFactoryFixed fixedFactory = new GroupcoinFactoryFixed(address(weth), 1 ether);
        uint256 paid = 1 ether + 1616692000000000;
        vm.deal(address(this), paid);
        fixedFactory.buy{value: paid}(1, 8_357_110);
        fixedFactory.launchGroupCoinToUniswapV3(1);

        assertEq(address(fixedFactory).balance, 0, "no dust");
        assertEq(weth.balanceOf(address(fixedFactory)), paid, "all wrapped");
    }
}
