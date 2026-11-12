// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Asset,
    FlashLender,
    FlashLenderFixed,
    HonestReceiver
} from "./58100-h-03-flash-loan-not-working-due-to-transferfrom-issue-pashov.sol";

contract Finding58100Test is Test {
    function test_exploit_flash_loan_reverts_and_loan_stays_put() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.LOAN(), 250_000e6, "loan size");
        assertEq(e.FEE(), 2_500e6, "fee size");
        assertTrue(e.vulnReverted(), "legitimate borrow reverted");
        assertEq(e.selfAllowance(), 0, "vault never approved itself");
        assertEq(e.vulnReceived(), 0, "borrower received nothing");
        assertEq(e.vaultBalanceAfter(), 250_000e6, "250000 USDC cannot be borrowed");
        assertEq(e.lender().totalLent(), 0, "failed lend did not stick");

        assertEq(e.controlReceived(), 250_000e6, "control transferred the loan");
        assertEq(e.controlRepaid(), 252_500e6, "control repaid loan plus fee");
        assertEq(e.controlVaultAfter(), 252_500e6, "control vault kept the fee");
    }

    function test_control_transfer_and_repay() public {
        Asset asset = new Asset();
        FlashLenderFixed lender = new FlashLenderFixed(asset);
        HonestReceiver receiver = new HonestReceiver(asset);

        uint256 loan = 250_000e6;
        uint256 fee = 2_500e6;
        asset.mint(address(lender), loan);
        asset.mint(address(receiver), fee);

        lender.flashLoanSimple(receiver, loan, "");

        assertEq(receiver.received(), loan, "receiver was transferred the loan");
        assertEq(receiver.repaid(), loan + fee, "receiver repaid loan plus fee");
        assertEq(asset.balanceOf(address(lender)), loan + fee, "vault is richer by the fee");
        assertEq(asset.balanceOf(address(receiver)), 0, "receiver did not keep the principal");
    }
}
