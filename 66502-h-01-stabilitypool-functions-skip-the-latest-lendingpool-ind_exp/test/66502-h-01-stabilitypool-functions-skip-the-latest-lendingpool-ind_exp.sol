// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Asset, LendingPool, RToken, StabilityPool} from
    "./66502-h-01-stabilitypool-functions-skip-the-latest-lendingpool-ind.sol";

contract Finding66502Test is Test {
    function test_stale_index_overpays_depositor() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.paid(), 3 ether, "stale path pays 3");
        assertEq(e.fair(), 2 ether, "fresh index would pay 2");
        assertEq(e.asset().balanceOf(address(e)), 3 ether, "attacker received 3");
        assertEq(e.lending().cash(), 7 ether, "suppliers left with 7, not 8");
        assertEq(e.lending().liquidityIndex(), 1e27, "index was not updated");
        assertEq(e.lending().pendingInterest(), 5 ether, "pending interest untouched");
    }

    function test_control_updateState_pays_two() public {
        Asset asset = new Asset();
        RToken rToken = new RToken();
        LendingPool lending = new LendingPool(asset);
        StabilityPool pool = new StabilityPool(lending, rToken);
        lending.seed(10 ether, 5 ether);
        rToken.mintScaled(address(this), 3 ether, 1e27);

        lending.updateState();
        assertEq(lending.liquidityIndex(), 1.5e27, "index refreshed");
        assertEq(lending.cash(), 15 ether, "interest pulled in");

        pool.deposit(3 ether);
        assertEq(pool.lastRaw(), 2 ether, "fresh formula pays 2");
        assertEq(asset.balanceOf(address(this)), 2 ether, "depositor received 2");
        assertEq(lending.cash(), 13 ether, "suppliers keep the other token");
    }
}
