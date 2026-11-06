// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {
    Exploit,
    Asset,
    AsyncSynthVault,
    Shareholder,
    Delegate
} from "./30917-h-2-calling-requestredeem-with-msgsender-owner-will-lead-to.sol";

/// Control: the recommended fix writes lastRedeemRequestId on the receiver.
contract FixedAsyncSynthVault is AsyncSynthVault {
    constructor(Asset asset_) AsyncSynthVault(asset_) {}

    function _createRedeemRequest(uint256 shares, address receiver, address, bytes calldata data)
        internal
        override
    {
        epochs[epochId].redeemRequestBalance[receiver] += shares;
        lastRedeemRequestId[receiver] = epochId;
        if (data.length != 0) revert("receiver hook");
    }
}

contract Finding30917Test is Test {
    function test_delegated_redeem_locks_twenty_assets() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.delegatePayout(), 0, "delegate payout");
        assertEq(e.ownerPayout(), 0, "owner payout");
        assertEq(e.lockedAssets(), 20 ether, "locked assets");
        assertEq(e.asset().balanceOf(address(e.shareOwner())), 0, "owner assets");
        assertEq(e.asset().balanceOf(address(e.delegate())), 0, "delegate assets");
        assertEq(e.vault().balanceOf(address(e.shareOwner())), 0, "owner shares");
        assertEq(e.vault().balanceOf(address(e.delegate())), 0, "delegate shares");
        assertEq(e.vault().lastRedeemRequestId(address(e.shareOwner())), 1, "id stored on owner");
        assertEq(e.vault().lastRedeemRequestId(address(e.delegate())), 0, "delegate id unset");
        assertEq(e.vault().redeemRequestBalanceOf(1, address(e.delegate())), 20 ether, "stranded bucket");
        assertEq(e.asset().balanceOf(address(e.vault().claimableSilo())), 20 ether, "silo still holds 20");

        console2.log("delegate payout", e.delegatePayout());
        console2.log("owner payout", e.ownerPayout());
        console2.log("locked assets", e.lockedAssets());
    }

    function test_control_receiver_id_pays_the_delegate() public {
        Asset asset = new Asset();
        FixedAsyncSynthVault vault = new FixedAsyncSynthVault(asset);
        Shareholder shareOwner = new Shareholder(asset, vault);
        Delegate delegate = new Delegate();

        asset.mint(address(shareOwner), 20 ether);
        shareOwner.depositAll();
        shareOwner.approveDelegate(address(delegate));
        vault.close();
        delegate.request(vault, 20 ether, address(delegate), address(shareOwner));
        vault.settle();

        uint256 ownerPaid = shareOwner.claim();
        uint256 paid = delegate.claim(vault);

        assertEq(vault.lastRedeemRequestId(address(delegate)), 1, "id written on receiver");
        assertEq(vault.lastRedeemRequestId(address(shareOwner)), 0, "owner was not tagged");
        assertEq(ownerPaid, 0, "owner is not the claimant");
        assertEq(paid, 20 ether, "receiver was not paid 20");
        assertEq(asset.balanceOf(address(delegate)), 20 ether, "delegate balance");
        assertEq(asset.balanceOf(address(shareOwner)), 0, "owner still empty");
        assertEq(asset.balanceOf(address(vault.claimableSilo())), 0, "silo emptied");
        assertEq(vault.balanceOf(address(shareOwner)), 0, "shares spent");
        assertEq(vault.epochId(), 2, "epoch advanced");

        console2.log("control delegate payout", paid);
        console2.log("control owner payout", ownerPaid);
    }
}
