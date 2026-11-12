// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    Depositor,
    Exploit,
    FeeControllerFixed,
    FeeType,
    NotOwner,
    Vault
} from "./61597-missing-access-control-on-critical-feecontroller-setters-cyf.sol";

contract VaultFixed {
    Asset public token;
    FeeControllerFixed public fees;

    constructor(Asset token_, FeeControllerFixed fees_) {
        token = token_;
        fees = fees_;
    }

    function deposit(address user, uint256 amount) external {
        token.transferFrom(user, address(this), amount);
        (, uint256 pct) = fees.functionFeeConfigs(this.deposit.selector);
        uint256 fee = amount * pct / 10000;
        if (fee != 0) token.transfer(msg.sender, fee);
    }
}

contract Finding61597Test is Test {
    function test_exploit_sets_100_percent_and_takes_deposit() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.taken(), 100 ether, "executor took N");
        assertEq(e.token().balanceOf(address(e)), 100 ether, "balance");
        assertEq(e.token().balanceOf(address(e.vault())), 0, "vault empty");
        emit log_named_uint("fee taken", e.taken());
    }

    function test_control_owner_gate_and_deposit_keeps_funds() public {
        Asset token = new Asset();
        FeeControllerFixed fees = new FeeControllerFixed(address(0xB0B));
        VaultFixed vault = new VaultFixed(token, fees);
        Depositor user = new Depositor();
        token.mint(address(user), 100 ether);
        user.approveToken(address(token), address(vault), 100 ether);

        vm.expectRevert(NotOwner.selector);
        fees.setFunctionFeeConfig(vault.deposit.selector, FeeType.Percent, 10000);

        vault.deposit(address(user), 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether, "deposit kept N");
        assertEq(token.balanceOf(address(this)), 0, "caller took 0");
    }
}
