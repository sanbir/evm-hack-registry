// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, CrossChainRouter, LendStorage, Usd} from
    "./58394-h-25-incorrect-desteid-value-in-handleliquidationsuccess-pr.sol";

contract Finding58394Test is Test {
    function test_exploit_escrow_stuck() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.usd().balanceOf(address(e.router())), 500e18, "500 stuck");
        assertEq(e.usd().balanceOf(address(this)), 500e18, "control paid 500");
    }

    function test_control_pays_the_escrow() public {
        Usd usd = new Usd();
        LendStorage store = new LendStorage();
        CrossChainRouter router = new CrossChainRouter(store, usd, 101);
        address borrower = address(0xB0B0);
        address lToken = address(0x1701);
        address underlying = address(0xA55E7);
        store.setUnderlying(lToken, underlying);
        store.add(
            borrower,
            underlying,
            LendStorage.Borrow({
                srcEid: 101,
                destEid: 2,
                principle: 500e18,
                borrowedlToken: lToken,
                srcToken: underlying
            })
        );
        router.escrow(500e18);
        router.handleLiquidationSuccessFixed(
            CrossChainRouter.Payload({
                amount: 500e18,
                sender: borrower,
                destlToken: lToken,
                liquidator: address(this),
                srcToken: underlying
            }),
            2
        );
        assertEq(usd.balanceOf(address(this)), 500e18, "paid 500");
        assertEq(usd.balanceOf(address(router)), 0, "nothing stuck");
    }
}
