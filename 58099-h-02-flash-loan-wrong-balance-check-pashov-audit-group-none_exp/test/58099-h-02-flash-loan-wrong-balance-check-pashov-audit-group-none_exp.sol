// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    As4626,
    IFlashLoanReceiver
} from "./58099-h-02-flash-loan-wrong-balance-check-pashov-audit-group-none.sol";

/// @dev Repays exactly `amount`. Enough for the fixed check, not for the buggy one.
contract HonestBorrower is IFlashLoanReceiver {
    Asset public asset;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function executeOperation(address, uint256 amount, uint256, address, bytes calldata) external returns (bool) {
        asset.transfer(msg.sender, amount);
        return true;
    }
}

/// @dev Auditor fix: snapshot after the tokens have left, and require amount + fee back.
contract As4626Fixed {
    Asset public asset;

    error FlashLoanDefault(address borrower, uint256 amount);

    constructor(Asset _asset) {
        asset = _asset;
        _asset.approve(address(this), type(uint256).max);
    }

    function flashLoanSimple(address receiver, uint256 amount, bytes calldata params) external {
        uint256 fee = 0;
        uint256 toRepay = amount + fee;
        asset.safeTransferFrom(address(this), receiver, amount);
        uint256 balanceBefore = asset.balanceOf(address(this));
        IFlashLoanReceiver(receiver).executeOperation(address(asset), amount, fee, msg.sender, params);
        if ((asset.balanceOf(address(this)) - balanceBefore) < toRepay) {
            revert FlashLoanDefault(msg.sender, amount);
        }
    }
}

contract Finding58099Test is Test {
    function test_exploit_vault_keeps_an_extra_1000() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.vaultBefore(), 1000 ether, "started at 1000");
        assertEq(e.repaid(), 2000 ether, "returned 2000");
        assertEq(e.vaultAfter(), 2000 ether, "vault ends at 2000");
        assertEq(e.vaultAfter() - e.vaultBefore(), 1000 ether, "extra 1000 kept");
        assertEq(e.asset().balanceOf(address(e)), 0, "borrower paid the extra");
    }

    function test_buggy_check_reverts_on_exact_repayment() public {
        Asset asset = new Asset();
        As4626 vault = new As4626(asset);
        HonestBorrower honest = new HonestBorrower(asset);
        asset.mint(address(vault), 1000 ether);

        vm.expectRevert(abi.encodeWithSelector(As4626.FlashLoanDefault.selector, address(this), 1000 ether));
        vault.flashLoanSimple(address(honest), 1000 ether, "");
        assertEq(asset.balanceOf(address(vault)), 1000 ether, "reverted loan moved nothing");
    }

    function test_control_accepts_full_repayment() public {
        Asset asset = new Asset();
        As4626Fixed vault = new As4626Fixed(asset);
        HonestBorrower honest = new HonestBorrower(asset);
        asset.mint(address(vault), 1000 ether);

        vault.flashLoanSimple(address(honest), 1000 ether, "");
        assertEq(asset.balanceOf(address(vault)), 1000 ether, "full repayment leaves the vault unchanged");
        assertEq(asset.balanceOf(address(honest)), 0, "borrower returned exactly 1000");
    }
}
