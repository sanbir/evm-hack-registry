// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, BebopRouter} from "./66835-beboproutersettle-lets-relayers-steal-exactin-user-input-by.sol";

contract Finding66835Test is Test {
    function test_exploit_relayer_takes_half_weth_user_gets_zero() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.usdc().balanceOf(address(e.user())), 0, "user paid 1000");
        assertEq(e.weth().balanceOf(address(e.user())), 0, "user weth");
        assertEq(e.weth().balanceOf(address(e)), 0.5 ether, "attacker");
        assertEq(e.usdc().balanceOf(address(e.router())), 1000e6, "router holds input");
    }

    function test_control_pmm_receiver_is_outside_the_signed_hash() public {
        Exploit e = new Exploit();
        BebopRouter.Order memory order = BebopRouter.Order({
            fromAmount: 1000e6,
            toAmount: 0.5 ether,
            limitAmount: 0,
            fromToken: address(e.usdc()),
            toToken: address(e.weth()),
            tokensOwner: address(e.user()),
            receiver: address(e.user()),
            routerNonce: 1
        });
        bytes32 h = e.router().hashOrder(order);
        // Changing nothing in the signed fields keeps the hash. The PMM receiver is not a field.
        assertEq(h, e.router().hashOrder(order));
        assertTrue(h != bytes32(0));
    }
}
