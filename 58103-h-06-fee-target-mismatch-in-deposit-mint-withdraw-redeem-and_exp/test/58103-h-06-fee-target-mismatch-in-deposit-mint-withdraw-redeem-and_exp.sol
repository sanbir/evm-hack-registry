// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Asset,
    ExemptAccount,
    Exploit,
    VaultFixed
} from "./58103-h-06-fee-target-mismatch-in-deposit-mint-withdraw-redeem-and.sol";

contract Finding58103Test is Test {
    function test_exploit_pays_10000_receives_shares_priced_as_9000() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.receiverQuote(), 10_000 ether, "exempt receiver preview quotes 10000");
        assertEq(e.sharesMinted(), 9_000 ether, "execution minted shares priced as 9000");
        assertEq(e.feesBooked(), 0, "fee ledger used the exempt receiver and booked 0");
        assertEq(e.positionValue(), 9_500 ether, "those shares are worth 9500");
        assertEq(e.asset().balanceOf(address(e.vault())), 19_000 ether, "vault holds the 10000 payment");
        assertLt(e.positionValue(), 10_000 ether, "depositor is short versus what they paid");
    }

    function test_control_preview_and_execution_use_the_caller() public {
        Asset asset = new Asset();
        VaultFixed vault = new VaultFixed(asset);
        ExemptAccount exempt = new ExemptAccount();
        vault.setExempt(address(exempt), true);

        asset.mint(address(this), 19_000 ether);
        asset.approve(address(exempt), 9_000 ether);
        exempt.seedFixed(asset, vault, 9_000 ether);

        uint256 preview = vault.previewDeposit(10_000 ether);
        asset.approve(address(vault), 10_000 ether);
        uint256 shares = vault.deposit(10_000 ether, address(exempt));

        assertEq(shares, preview, "minted shares match the caller preview");
        assertEq(shares, 9_000 ether, "caller is not exempt, so the haircut remains");
        uint256 booked = vault.revBp(10_000 ether, vault.ENTRY());
        assertEq(vault.claimableAssetFees(), booked, "execution booked the caller's fee");
        assertGt(booked, 0, "fee ledger is no longer zero");
    }
}
