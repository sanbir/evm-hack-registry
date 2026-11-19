// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {
    Exploit,
    BondToken,
    BondManagerFixed
} from "./60331-relayers-bond-funds-can-be-lost-quantstamp-pheasant-network.sol";

contract PoC_60331_BondOverwrite is Test {
    function test_run_overwrittenRequestLocks100() public {
        Exploit exp = new Exploit();
        exp.run();

        uint256 stuck = exp.token().balanceOf(address(exp.mgr())) - exp.mgr().bonds(1);
        emit log_named_decimal_uint("bond tokens stuck", stuck, 18);
        emit log_named_decimal_uint("paid to the depositor", exp.token().balanceOf(address(exp)), 18);

        assertEq(stuck, 100 ether, "stuck");
        assertEq(exp.marker().balanceOf(exp.SINK()), 100 ether, "marker");
        assertEq(exp.token().balanceOf(address(exp)), 300 ether, "paid");
        assertEq(exp.mgr().bonds(1), 600 ether, "bonds");
    }

    function test_control_finalizeBetweenRequestsPaysBoth() public {
        BondToken token = new BondToken();
        BondManagerFixed mgr = new BondManagerFixed(token);
        token.mint(address(this), 1000 ether);
        token.approve(address(mgr), 1000 ether);
        mgr.deposit(1, 1000 ether);
        mgr.executeWithdrawBond(1, 100 ether);
        mgr.finalizeWithdrawalBond();
        mgr.executeWithdrawBond(1, 300 ether);
        mgr.finalizeWithdrawalBond();

        uint256 stuck = token.balanceOf(address(mgr)) - mgr.bonds(1);
        emit log_named_decimal_uint("control stuck", stuck, 18);

        assertEq(token.balanceOf(address(this)), 400 ether, "both requests paid");
        assertEq(stuck, 0, "nothing stuck");
        assertTrue(stuck != 100 ether, "must not hit the locked amount");
    }
}
