// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    MockToken,
    FulfillableRegistry,
    BandoERC20FulfillableV1,
    BandoFulfillmentManagerFixed
} from "./45848-lack-of-an-implementation-for-withdrawing-beneficiaries-bala.sol";

contract Finding45848Test is Test {
    address internal constant BENEFICIARY = 0x2222222222222222222222222222222222222222;
    uint256 internal constant LOCKED = 1000 ether;

    function test_exploit_beneficiary_balance_stuck() public {
        Exploit e = new Exploit();
        e.run();

        MockToken token = e.token();
        address escrow = address(e.escrow());

        assertEq(e.stuck(), LOCKED, "N tokens recorded stuck");
        assertEq(token.balanceOf(escrow), LOCKED, "escrow still holds N");
        assertEq(token.balanceOf(BENEFICIARY), 0, "beneficiary received nothing");
        assertEq(e.escrow()._releaseablePools(address(token)), LOCKED, "pool still N");
        assertFalse(e.directWithdrawSucceeded(), "escrow withdraw reverted");
        assertFalse(e.managerWithdrawSucceeded(), "manager withdraw does not exist");
    }

    function test_control_added_withdraw_pays_beneficiary() public {
        MockToken token = new MockToken();
        FulfillableRegistry registry = new FulfillableRegistry();
        BandoERC20FulfillableV1 escrow = new BandoERC20FulfillableV1(address(registry));
        BandoFulfillmentManagerFixed manager = new BandoFulfillmentManagerFixed(address(escrow), address(registry));
        escrow.setManager(address(manager));
        registry.setService(1, payable(BENEFICIARY));

        token.mint(address(this), LOCKED);
        token.approve(address(manager), LOCKED);
        manager.registerFulfillment(1, address(token), LOCKED);
        assertEq(token.balanceOf(address(escrow)), LOCKED, "precondition: N sitting");

        vm.prank(BENEFICIARY);
        manager.beneficiaryWithdraw(1, address(token));

        assertEq(token.balanceOf(BENEFICIARY), LOCKED, "control pays the beneficiary N");
        assertEq(token.balanceOf(address(escrow)), 0, "escrow emptied");
        assertEq(escrow._releaseablePools(address(token)), 0, "pool cleared");
    }
}
