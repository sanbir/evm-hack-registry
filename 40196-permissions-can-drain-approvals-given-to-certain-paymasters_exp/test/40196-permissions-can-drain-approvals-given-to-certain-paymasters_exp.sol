// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {
    Exploit,
    MockToken,
    Wallet,
    PermissionManager,
    ChargingPaymaster,
    Permission,
    DisabledPaymaster
} from "./40196-permissions-can-drain-approvals-given-to-certain-paymasters.sol";

/// Fix: the allowlist is checked in validation, before the paymaster can charge.
contract FixedPermission {
    mapping(address => bool) public isPaymasterEnabled;

    function setPaymasterEnabled(address paymaster, bool enabled) external {
        isPaymasterEnabled[paymaster] = enabled;
    }

    function validateUserOp(address paymaster) external view returns (uint256) {
        if (!isPaymasterEnabled[paymaster]) revert DisabledPaymaster(paymaster);
        return 0;
    }
}

contract Finding40196Test is Test {
    function test_exploit_non_allowlisted_paymaster_keeps_the_approval() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.stolen(), 1000e6, "drained");
        assertEq(e.walletLeft(), 0, "wallet");
        assertTrue(e.executionReverted(), "execution did not fail");
        assertFalse(e.chargerEnabled(), "charger was enabled");
        assertEq(e.profit(), 1000e6, "profit");
        assertTrue(e.permissions().isPaymasterEnabled(address(e.allowed())), "allowed paymaster");

        console.log("approval USDC", uint256(1000e6));
        console.log("wallet USDC left", e.walletLeft());
        console.log("paymaster USDC taken", e.stolen());
        console.log("execution reverted", e.executionReverted() ? 1 : 0);
    }

    function test_control_validation_check_stops_the_charge() public {
        MockToken usdc = new MockToken("USD Coin", "USDC");
        Wallet wallet = new Wallet();
        FixedPermission fixedPermission = new FixedPermission();
        ChargingPaymaster charger = new ChargingPaymaster();

        usdc.mint(address(wallet), 1000e6);
        wallet.approveToken(address(usdc), address(charger), 1000e6);
        fixedPermission.setPaymasterEnabled(address(0xBEEF), true);

        vm.expectRevert(abi.encodeWithSelector(DisabledPaymaster.selector, address(charger)));
        fixedPermission.validateUserOp(address(charger));

        assertEq(usdc.balanceOf(address(wallet)), 1000e6, "charged anyway");
        assertEq(usdc.balanceOf(address(charger)), 0, "paymaster paid");
        console.log("control wallet USDC", usdc.balanceOf(address(wallet)));
    }
}
