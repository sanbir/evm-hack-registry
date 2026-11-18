// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, ERC20Mini, LendStorage, RouterFixed} from "./58373-h-4-cross-chain-liquidation-uses-incorrect-ltoken-address-pr.sol";

contract Finding58373Test is Test {
    function test_exploit_seize_without_repayment() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.debtLeft(), 800 ether, "debt");
        assertEq(e.seized(), 1000 ether, "seized");
        assertEq(e.collateral().balanceOf(address(e)), 1000 ether, "liquidator");
        assertFalse(e.router().repaymentApplied(), "repaid");
    }

    function test_control_chain_b_ltoken_repays() public {
        ERC20Mini collateral = new ERC20Mini();
        LendStorage store = new LendStorage();
        address lToken = address(0xBEEF);
        address asset = address(0xA55E7);
        store.setUnderlying(lToken, asset);
        RouterFixed router = new RouterFixed(store, collateral, lToken, asset);
        router.seed(address(0xB0B), 1000 ether, 800 ether);
        router.liquidate(address(0xB0B));
        assertEq(router.debt(address(0xB0B)), 0, "repaid");
        assertEq(collateral.balanceOf(address(this)), 1000 ether, "seized");
    }
}
