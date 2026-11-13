// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {Exploit, Cvx, Locker, VeStrategy} from "./42292-h-01-vecvxstrategymanualrebalance-has-wrong-logic-code4rena.sol";

contract Finding42292Test is Test {
    function test_rebalance_locks_the_liquid_balance() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.strat().lastLocked(), 200 ether, "locked all liquid");
        assertEq(e.cvx().balanceOf(address(e.locker())), 1000 ether, "locker");
        assertEq(e.cvx().balanceOf(address(e.strat())), 0, "liquid");
        console2.log("cvx locked this call", e.strat().lastLocked());
        console2.log("cvxToLock before cap", e.strat().lastCvxToLock());
    }

    function test_control_locks_only_the_shortfall() public {
        Cvx cvx = new Cvx();
        Locker locker = new Locker(cvx);
        VeStrategy strat = new VeStrategy(cvx, locker);
        cvx.mint(address(locker), 800 ether);
        locker.sync(address(strat), 800 ether);
        cvx.mint(address(strat), 200 ether);
        strat.manualRebalanceFixed(9000);
        assertEq(locker.balanceOf(address(strat)), 900 ether, "50-to-90 target");
        assertEq(cvx.balanceOf(address(strat)), 100 ether, "100 stays liquid");
        assertEq(cvx.balanceOf(address(locker)), 900 ether, "locker token");
        console2.log("control liquid left", cvx.balanceOf(address(strat)));
        console2.log("control locked", locker.balanceOf(address(strat)));
    }
}
