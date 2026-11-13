// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    WETH,
    MockStargateRouter,
    ArbitrumSwaps,
    Thief
} from "./20422-h-01-anyone-can-use-or-steal-arbitrumswaps-native-asset-bala.sol";

contract ArbitrumSwapsFixed is ArbitrumSwaps {
    constructor(WETH weth_, MockStargateRouter router_) ArbitrumSwaps(weth_, router_) {}

    function stargateSwap() external payable override {
        router.swap{value: msg.value}(payable(msg.sender));
    }
}

contract Finding20422Test is Test {
    receive() external payable {}

    function test_exploit_refund_is_stolen_with_weth_steps() public {
        Exploit e = new Exploit();
        e.run{value: 3 ether}();
        assertEq(address(e.thief()).balance, 2 ether, "thief took the 2 ETH refund");
        assertEq(address(e.router()).balance, 1 ether, "1 ETH stayed bridged");
        assertEq(address(e.swaps()).balance, 0, "router holds nothing");
    }

    function test_control_refund_returns_to_the_swapper() public {
        WETH weth = new WETH();
        MockStargateRouter router = new MockStargateRouter();
        ArbitrumSwapsFixed swaps = new ArbitrumSwapsFixed(weth, router);
        Thief thief = new Thief(ArbitrumSwaps(payable(address(swaps))));
        uint256 before = address(this).balance;
        swaps.stargateSwap{value: 3 ether}();
        assertEq(address(swaps).balance, 0, "no parked refund");
        assertEq(address(this).balance, before - 1 ether, "swapper kept the 2 ETH refund");
        thief.steal();
        assertEq(address(thief).balance, 0, "nothing to steal");
        assertEq(address(router).balance, 1 ether, "bridge amount unchanged");
    }
}
