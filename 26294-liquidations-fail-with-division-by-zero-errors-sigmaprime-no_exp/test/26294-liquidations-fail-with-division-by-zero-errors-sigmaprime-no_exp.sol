// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    Servicer,
    PriceOracle,
    Locker,
    BatchLiquidationFixed,
    Receiver
} from "./26294-liquidations-fail-with-division-by-zero-errors-sigmaprime-no.sol";

contract Finding26294Test is Test {
    function test_exploit_liquidation_reverts_and_collateral_stays() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.coll().balanceOf(address(e.locker())), 1_000 ether, "1000 stuck");
        assertEq(e.coll().balanceOf(address(e)), 0, "liquidator empty");
    }

    function test_control_complete_liquidation_pays_collateral() public {
        MockToken coll = new MockToken();
        Servicer servicer = new Servicer();
        PriceOracle oracle = new PriceOracle();
        Receiver borrower = new Receiver();
        Locker locker = new Locker(address(coll), address(this));
        BatchLiquidationFixed liq = new BatchLiquidationFixed(
            address(servicer), address(oracle), address(locker), address(coll), address(borrower)
        );
        servicer.setObligation(address(borrower), 500 ether);
        coll.mint(address(locker), 1_000 ether);

        liq.batchLiquidation();

        assertEq(coll.balanceOf(address(this)), 1_000 ether, "liquidator received 1000");
        assertEq(coll.balanceOf(address(locker)), 0, "locker empty");
        assertEq(servicer.getBorrowerRepurchaseObligation(address(borrower)), 0, "debt cleared");
    }
}
